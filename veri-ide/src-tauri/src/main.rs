use std::fs;
use std::path::PathBuf;
use std::process::{Child, Command};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, OnceLock};
use std::thread;
use std::time::Duration;
use tauri::{
    menu::{Menu, MenuItem},
    tray::TrayIconBuilder,
    AppHandle, Manager,
};

const SIDECAR_PORT: &str = "8000";

/// The sidecar process, kept so the shell can take it along when it exits.
static SIDECAR: OnceLock<Mutex<Option<Child>>> = OnceLock::new();

/// Set while tearing down, so the supervisor stops reviving the sidecar it is
/// about to kill.
static SHUTTING_DOWN: AtomicBool = AtomicBool::new(false);

fn sidecar_slot() -> &'static Mutex<Option<Child>> {
    SIDECAR.get_or_init(|| Mutex::new(None))
}

struct Sidecar {
    python: PathBuf,
    work_dir: PathBuf,
    bin_dir: Option<PathBuf>,
}

/// The interpreter and tool directory that the bundle ships.
///
/// `package.sh` lays the virtualenv and the two runtime tools into
/// `bundle.resources`, which Tauri installs under `resource_dir()`. Carrying them
/// means the packaged app needs neither this checkout nor a system `python3` that
/// can import `veri_ide`.
fn bundled_sidecar(app: &AppHandle) -> Option<Sidecar> {
    let resource_dir = app.path().resource_dir().ok()?;
    // Tauri also materialises `bundle.resources` beside the executable while the
    // app runs from a Cargo output directory, so resource dir == exe dir means
    // "build tree, not installed bundle". There the developer's own interpreter
    // has to run, or an edit to the sidecar would only show up after a bundling.
    let exe_dir = std::env::current_exe().ok()?.parent()?.to_path_buf();
    if resource_dir == exe_dir {
        return None;
    }
    let python = resource_dir.join("python").join("bin").join("python3");
    if !python.is_file() {
        return None;
    }
    // A bundle's own tree may be a read-only mount (AppImage), so the sidecar runs
    // where it can write.
    let work_dir = app
        .path()
        .app_data_dir()
        .unwrap_or_else(|_| std::env::temp_dir());
    let _ = fs::create_dir_all(&work_dir);
    Some(Sidecar {
        python,
        work_dir,
        bin_dir: Some(resource_dir.join("bin")),
    })
}

/// A working tree: `tauri dev` runs with the working directory set to src-tauri,
/// so the component root is its parent. The interpreter is the one the developer
/// installed the package with -- `$PYTHON`, else the component virtualenv, else
/// whatever `python3` resolves to.
fn dev_sidecar() -> Sidecar {
    let project_root = std::env::current_dir()
        .ok()
        .and_then(|cwd| cwd.parent().map(|parent| parent.to_path_buf()))
        .unwrap_or_else(|| PathBuf::from("."));
    let python = std::env::var_os("PYTHON")
        .map(PathBuf::from)
        .or_else(|| {
            let venv = project_root.join(".venv").join("bin").join("python3");
            if venv.is_file() {
                Some(venv)
            } else {
                None
            }
        })
        .unwrap_or_else(|| PathBuf::from("python3"));
    Sidecar {
        python,
        work_dir: project_root,
        bin_dir: None,
    }
}

fn launch(sidecar: &Sidecar) -> Result<Child, String> {
    let mut command = Command::new(&sidecar.python);
    command
        .arg("-m")
        .arg("uvicorn")
        .arg("veri_ide.api.server:app")
        .arg("--host")
        .arg("127.0.0.1")
        .arg("--port")
        .arg(SIDECAR_PORT)
        .current_dir(&sidecar.work_dir);
    if let Some(bin_dir) = &sidecar.bin_dir {
        command.env("VERIDE_BIN_DIR", bin_dir);
    }
    // The AppImage runtime exports PYTHONHOME/PYTHONPATH for its own tree, which
    // the bundled interpreter reads before pyvenv.cfg and then dies with "Failed to
    // import encodings". Those variables describe a different Python.
    command.env_remove("PYTHONHOME").env_remove("PYTHONPATH");
    command.spawn().map_err(|e| e.to_string())
}

/// Start the sidecar, and keep the desktop shell from outliving it: an orphan left
/// on 127.0.0.1:8000 makes the next launch fail in a way that looks like a broken
/// bundle rather than a stale process.
fn start_sidecar(app: &AppHandle) {
    let sidecar = bundled_sidecar(app).unwrap_or_else(dev_sidecar);
    eprintln!(
        "Starting sidecar: {} (VERIDE_BIN_DIR={:?})",
        sidecar.python.display(),
        sidecar.bin_dir
    );

    let app = app.clone();
    thread::spawn(move || {
        for attempt in 1..=5 {
            let child = match launch(&sidecar) {
                Ok(child) => child,
                Err(e) => {
                    eprintln!("Failed to start FastAPI sidecar: {}", e);
                    thread::sleep(Duration::from_millis(500));
                    continue;
                }
            };
            *sidecar_slot().lock().unwrap() = Some(child);

            let status = sidecar_slot()
                .lock()
                .unwrap()
                .as_mut()
                .and_then(|child| child.wait().ok());

            if SHUTTING_DOWN.load(Ordering::SeqCst) {
                break;
            }
            if attempt == 5 {
                eprintln!("Giving up on the FastAPI sidecar after 5 attempts");
                break;
            }
            eprintln!("FastAPI sidecar stopped ({status:?}); reviving");
            thread::sleep(Duration::from_millis(500));
            if let Some(window) = app.get_webview_window("main") {
                // The displayed values belong to the process that just died.
                let _ = window.eval("location.reload()");
            }
        }
    });

    // Windows are created on the event loop's first iteration, which has not run
    // yet here, but the sidecar still needs a second to import the app: the UI
    // waits for /health rather than assuming the port already answers.
}

/// Take the sidecar down with the shell.
fn stop_sidecar() {
    SHUTTING_DOWN.store(true, Ordering::SeqCst);
    if let Some(child) = sidecar_slot().lock().unwrap().as_mut() {
        let _ = child.kill();
        let _ = child.wait();
    }
}

fn main() -> tauri::Result<()> {
    let app = tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_dialog::init())
        .setup(|app| {
            // Create system tray
            let quit = MenuItem::with_id(app, "quit", "退出 VeriIDE", true, None::<&str>)?;
            let show = MenuItem::with_id(app, "show", "显示窗口", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&show, &quit])?;

            TrayIconBuilder::new()
                .icon(app.default_window_icon().unwrap().clone())
                .menu(&menu)
                .on_menu_event(|app, event| match event.id().as_ref() {
                    "quit" => {
                        app.exit(0);
                    }
                    "show" => {
                        if let Some(window) = app.get_webview_window("main") {
                            window.show().unwrap();
                            window.set_focus().unwrap();
                        }
                    }
                    _ => {}
                })
                .build(app)?;

            Ok(())
        })
        .build(tauri::generate_context!())?;

    start_sidecar(app.handle());

    app.run(|_handle, event| match event {
        tauri::RunEvent::Exit => stop_sidecar(),
        _ => {}
    });
    Ok(())
}
