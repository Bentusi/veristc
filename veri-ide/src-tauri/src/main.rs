use std::net::TcpStream;
use std::process::Command;
use std::thread;
use std::time::Duration;
use tauri::{
    menu::{Menu, MenuItem},
    tray::TrayIconBuilder,
    Manager,
};

fn start_fastapi_server() {
    thread::spawn(|| {
        let python = std::env::var("PYTHON").unwrap_or_else(|_| "python3".to_string());
        let project_root = std::env::current_dir()
            .unwrap()
            .parent()
            .unwrap()
            .to_path_buf();

        loop {
            let status = Command::new(&python)
                .arg("-m")
                .arg("uvicorn")
                .arg("veri_ide.api.server:app")
                .arg("--host")
                .arg("127.0.0.1")
                .arg("--port")
                .arg("8000")
                .current_dir(&project_root)
                .status();

            match status {
                Ok(s) if !s.success() => {
                    eprintln!("FastAPI server exited with: {}", s);
                    break;
                }
                Err(e) => {
                    eprintln!("Failed to start FastAPI server: {}", e);
                    break;
                }
                _ => {}
            }

            thread::sleep(Duration::from_secs(1));
        }
    });

    // Wait for server to be ready
    for _ in 0..30 {
        thread::sleep(Duration::from_millis(500));
        if TcpStream::connect("127.0.0.1:8000").is_ok() {
            println!("FastAPI server is ready");
            return;
        }
    }
    eprintln!("Warning: FastAPI server may not be ready");
}

fn main() {
    // Start FastAPI backend
    start_fastapi_server();

    tauri::Builder::default()
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
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
