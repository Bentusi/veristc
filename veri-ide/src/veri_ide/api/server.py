"""VeriIDE REST API backend."""

import tempfile
from pathlib import Path
from typing import Optional

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

from ..backend.build.service import build_project, find_veristc_binary
from ..backend.project.service import create_project, open_project
from ..backend.pre.merge import write_merged_file
from ..backend.deploy.service import DeployService, DeployResult, TargetConfig
from ..backend.deploy.key_manager import KeyManager, KeyManagerError
from ..backend.collaboration.router import router as collaboration_router
from ..backend.monitor.router import router as monitor_router
from ..backend.library.router import router as library_router
from ..backend.device.router import router as device_router
from ..backend.graph.router import router as graph_router
from ..backend.sim.router import router as sim_router


_FRONTEND_DIR = Path(__file__).resolve().parent.parent.parent.parent / "frontend" / "public"


app = FastAPI(
    title="VeriIDE API",
    description="Backend API for VeriIDE ST editor",
    version="0.1.0",
)

# Enable CORS for frontend
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # In production, restrict to specific origins
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Serve frontend static files
if _FRONTEND_DIR.is_dir():
    app.mount("/static", StaticFiles(directory=str(_FRONTEND_DIR)), name="static")

# Include collaboration router
app.include_router(collaboration_router)

# Include monitor router
app.include_router(monitor_router)

# Include library router
app.include_router(library_router)

# Include device configuration router
app.include_router(device_router)

# Include graphical logic configuration router
app.include_router(graph_router)

# Include simulation router
app.include_router(sim_router)


class BuildRequest(BaseModel):
    """Build request payload."""
    code: str
    project_name: Optional[str] = "temp_project"


class DiagnosticResponse(BaseModel):
    """Diagnostic message."""
    severity: str
    message: str
    line: Optional[int] = None
    column: Optional[int] = None
    pou: Optional[str] = None
    var: Optional[str] = None
    kind: Optional[str] = None


class BuildResponse(BaseModel):
    """Build result."""
    success: bool
    exit_code: int
    diagnostics: list[DiagnosticResponse]
    sasm_path: Optional[str] = None
    merged_st: Optional[str] = None


class HealthResponse(BaseModel):
    """Health check response."""
    status: str
    version: str
    veristc_available: bool


# Deploy endpoints

class DeployRequest(BaseModel):
    """Deploy request payload."""
    sasm_file: str
    target: TargetConfig
    key_hex: str
    download_at: int = 1
    health_cycles: int = 3


class DeployResponse(BaseModel):
    """Deploy result."""
    success: bool
    stages: list[str]
    status_frames: list[dict]
    errors: list[str]


class KeyGenerateRequest(BaseModel):
    """Key generation request."""
    name: str


class KeyResponse(BaseModel):
    """Key response."""
    name: str
    key_hex: Optional[str] = None
    exists: bool = False


class KeyListResponse(BaseModel):
    """Key list response."""
    keys: list[str]


class KeyInfoResponse(BaseModel):
    """Key info response."""
    name: str
    path: str
    size: int
    created: float
    modified: float


@app.get("/health", response_model=HealthResponse)
def health_check():
    """Health check endpoint."""
    try:
        find_veristc_binary()
        veristc_available = True
    except FileNotFoundError:
        veristc_available = False
    
    return HealthResponse(
        status="ok",
        version="0.1.0",
        veristc_available=veristc_available,
    )


@app.post("/build", response_model=BuildResponse)
def build_code(request: BuildRequest):
    """Build ST code and return diagnostics."""
    # Create temporary project
    with tempfile.TemporaryDirectory() as tmpdir:
        project_path = Path(tmpdir) / request.project_name
        
        try:
            # Create project structure
            create_project(
                name=request.project_name,
                target_path=project_path,
                safety_level="SIL2",
            )
            
            # Write ST code
            logic_dir = project_path / "logic"
            logic_dir.mkdir(exist_ok=True)
            main_st = logic_dir / "main.st"
            main_st.write_text(request.code, encoding="utf-8")
            
            # Update project.yaml
            import yaml
            with open(project_path / "project.yaml", "r") as f:
                project_data = yaml.safe_load(f)
            project_data["logic_files"] = ["main.st"]
            with open(project_path / "project.yaml", "w") as f:
                yaml.dump(project_data, f)
            
            # Build
            result = build_project(project_path)
            
            # Convert diagnostics
            diagnostics = [
                DiagnosticResponse(
                    severity=d.severity,
                    message=d.message,
                    line=d.loc.split(":")[-1] if d.loc and ":" in d.loc else None,
                    column=None,
                    pou=d.pou,
                    var=d.var,
                    kind=d.kind,
                )
                for d in result.diagnostics
            ]
            
            # Read merged ST if available
            merged_st = None
            if result.merged_st_path and result.merged_st_path.exists():
                merged_st = result.merged_st_path.read_text(encoding="utf-8")
            
            return BuildResponse(
                success=result.success,
                exit_code=result.exit_code,
                diagnostics=diagnostics,
                sasm_path=str(result.sasm_path) if result.sasm_path else None,
                merged_st=merged_st,
            )
            
        except Exception as e:
            raise HTTPException(status_code=500, detail=str(e))


@app.get("/")
def root():
    """Serve the main frontend page."""
    index = _FRONTEND_DIR / "index.html"
    if index.is_file():
        return FileResponse(str(index), media_type="text/html")
    return {"message": "VeriIDE API", "version": "0.1.0"}


@app.post("/deploy", response_model=DeployResponse)
def deploy_code(request: DeployRequest):
    """Deploy .sasm file to target."""
    try:
        service = DeployService()
        key_bytes = bytes.fromhex(request.key_hex)
        
        result = service.deploy(
            sasm_file=request.sasm_file,
            target=request.target,
            key=key_bytes,
            download_at=request.download_at,
            health_cycles=request.health_cycles,
        )
        
        return DeployResponse(
            success=result.success,
            stages=result.stages,
            status_frames=result.status_frames,
            errors=result.errors,
        )
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/keys/generate", response_model=KeyResponse)
def generate_key(request: KeyGenerateRequest):
    """Generate a new HMAC key."""
    try:
        manager = KeyManager()
        name = manager.generate_key(request.name)
        key_hex = manager.load_key_hex(name)
        return KeyResponse(name=name, key_hex=key_hex, exists=True)
    except KeyManagerError as e:
        raise HTTPException(status_code=400, detail=str(e))
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/keys", response_model=KeyListResponse)
def list_keys():
    """List all keys."""
    try:
        manager = KeyManager()
        keys = manager.list_keys()
        return KeyListResponse(keys=keys)
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/keys/{name}", response_model=KeyResponse)
def get_key(name: str):
    """Get key info."""
    try:
        manager = KeyManager()
        if not manager.key_exists(name):
            raise HTTPException(status_code=404, detail=f"Key not found: {name}")
        key_hex = manager.load_key_hex(name)
        return KeyResponse(name=name, key_hex=key_hex, exists=True)
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.delete("/keys/{name}")
def delete_key(name: str):
    """Delete a key."""
    try:
        manager = KeyManager()
        if not manager.key_exists(name):
            raise HTTPException(status_code=404, detail=f"Key not found: {name}")
        manager.delete_key(name)
        return {"message": f"Key deleted: {name}"}
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/keys/{name}/info", response_model=KeyInfoResponse)
def get_key_info(name: str):
    """Get key metadata."""
    try:
        manager = KeyManager()
        info = manager.get_key_info(name)
        return KeyInfoResponse(**info)
    except KeyManagerError as e:
        raise HTTPException(status_code=404, detail=str(e))
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


def run_server(host: str = "127.0.0.1", port: int = 8000):
    """Run the API server."""
    import uvicorn
    uvicorn.run(app, host=host, port=port)


if __name__ == "__main__":
    run_server()
