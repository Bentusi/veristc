"""VeriIDE REST API backend."""

import tempfile
from pathlib import Path
from typing import Optional

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

from ..backend.build.service import build_project, find_veristc_binary
from ..backend.project.service import create_project, open_project
from ..backend.pre.merge import write_merged_file


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
    """Root endpoint."""
    return {
        "message": "VeriIDE API",
        "version": "0.1.0",
        "endpoints": {
            "health": "/health",
            "build": "/build",
        }
    }


def run_server(host: str = "127.0.0.1", port: int = 8000):
    """Run the API server."""
    import uvicorn
    uvicorn.run(app, host=host, port=port)


if __name__ == "__main__":
    run_server()
