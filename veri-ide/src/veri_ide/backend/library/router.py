"""
算法块与算法库 API 路由

端点：
- 算法块 CRUD（支持 library_id 作用域）
- 多库管理（CRUD / 清空 / 验证 / ZIP 导入导出）
- 多维度分类筛选（时序/信号类型/分类）
- 向后兼容的 JSON 导入/导出
"""

import tempfile
from pathlib import Path

from fastapi import APIRouter, HTTPException, Query, UploadFile, File
from fastapi.responses import FileResponse
from pydantic import BaseModel
from typing import Optional, Any

from .service import get_library_service
from .models import BlockCategory, ClassificationFilter, SignalType


router = APIRouter(prefix="/library", tags=["library"])


# ========== Request/Response Models ==========

class BlockPortRequest(BaseModel):
    name: str
    direction: str
    data_type: str
    description: str = ""
    default_value: Any = None


class BlockParameterRequest(BaseModel):
    name: str
    data_type: str
    default_value: Any = None
    min_value: Optional[Any] = None
    max_value: Optional[Any] = None
    description: str = ""


class CreateBlockRequest(BaseModel):
    name: str
    category: str
    version: str = "1.0.0"
    description: str = ""
    author: str = ""
    block_kind: str = "FB"
    time_based: bool = False
    signal_type: str = "mixed"
    library_id: Optional[str] = None
    inputs: list[BlockPortRequest] = []
    outputs: list[BlockPortRequest] = []
    parameters: list[BlockParameterRequest] = []
    st_template: str = ""
    icon_svg: str = ""
    tags: list[str] = []


class UpdateBlockRequest(BaseModel):
    name: Optional[str] = None
    category: Optional[str] = None
    version: Optional[str] = None
    description: Optional[str] = None
    author: Optional[str] = None
    block_kind: Optional[str] = None
    time_based: Optional[bool] = None
    signal_type: Optional[str] = None
    inputs: Optional[list[BlockPortRequest]] = None
    outputs: Optional[list[BlockPortRequest]] = None
    parameters: Optional[list[BlockParameterRequest]] = None
    st_template: Optional[str] = None
    icon_svg: Optional[str] = None
    tags: Optional[list[str]] = None


class BlockResponse(BaseModel):
    id: str
    name: str
    category: str
    version: str
    description: str
    author: str
    created_at: str
    updated_at: str
    block_kind: str = "FB"
    time_based: bool = False
    signal_type: str = "mixed"
    library_id: str = ""
    inputs: list[dict]
    outputs: list[dict]
    parameters: list[dict]
    st_template: str
    icon_svg: str
    tags: list[str]
    sha256: str
    scope: str = "user"
    path: str = ""


class LibraryResponse(BaseModel):
    id: str
    name: str
    description: str
    owner: str
    version: str = "1.0.0"
    is_shared: bool
    blocks_count: int
    created_at: str
    updated_at: str
    schema_version: str = "2.0"
    classification_dims: dict = {}
    validation: dict = {}
    directory: str = ""


class ImportResultResponse(BaseModel):
    success: bool
    block_id: str = ""
    message: str = ""
    is_duplicate: bool = False


class CreateLibraryRequest(BaseModel):
    name: str
    description: str = ""
    owner: str = ""
    version: str = "1.0.0"
    library_id: Optional[str] = None


class UpdateLibraryRequest(BaseModel):
    name: Optional[str] = None
    description: Optional[str] = None
    owner: Optional[str] = None
    version: Optional[str] = None


class ValidationResponse(BaseModel):
    valid: bool
    errors: list[str] = []


# ========== Block Endpoints ==========

@router.get("/blocks", response_model=list[BlockResponse])
async def list_blocks(
    category: Optional[str] = Query(None),
    search: Optional[str] = Query(None),
    tag: Optional[str] = Query(None),
    library_id: Optional[str] = Query(None),
    time_based: Optional[bool] = Query(None),
    signal_type: Optional[str] = Query(None),
):
    """列出算法块（支持多维度筛选）"""
    service = get_library_service()

    cat = BlockCategory(category) if category else None
    classification = None
    if library_id is not None or time_based is not None or signal_type is not None:
        sig = None
        if signal_type:
            try:
                sig = SignalType(signal_type)
            except ValueError:
                pass
        classification = ClassificationFilter(
            library_id=library_id,
            time_based=time_based,
            signal_type=sig,
        )

    blocks = service.list_blocks(cat, search, tag, classification)
    return [BlockResponse(**b.to_dict()) for b in blocks]


@router.get("/blocks/{block_id}", response_model=BlockResponse)
async def get_block(block_id: str):
    """获取算法块详情"""
    service = get_library_service()
    block = service.get_block(block_id)
    if not block:
        raise HTTPException(status_code=404, detail="Block not found")
    return BlockResponse(**block.to_dict())


@router.post("/blocks", response_model=BlockResponse)
async def create_block(request: CreateBlockRequest):
    """创建算法块"""
    from .models import AlgorithmBlock, BlockPort, BlockParameter, PortDirection

    service = get_library_service()

    try:
        sig = SignalType(request.signal_type)
    except ValueError:
        sig = SignalType.MIXED

    block = AlgorithmBlock(
        id="",
        name=request.name,
        category=BlockCategory(request.category),
        version=request.version,
        description=request.description,
        author=request.author,
        block_kind=request.block_kind,
        time_based=request.time_based,
        signal_type=sig,
        inputs=[
            BlockPort(
                name=p.name,
                direction=PortDirection(p.direction),
                data_type=p.data_type,
                description=p.description,
                default_value=p.default_value,
            )
            for p in request.inputs
        ],
        outputs=[
            BlockPort(
                name=p.name,
                direction=PortDirection(p.direction),
                data_type=p.data_type,
                description=p.description,
                default_value=p.default_value,
            )
            for p in request.outputs
        ],
        parameters=[
            BlockParameter(
                name=p.name,
                data_type=p.data_type,
                default_value=p.default_value,
                min_value=p.min_value,
                max_value=p.max_value,
                description=p.description,
            )
            for p in request.parameters
        ],
        st_template=request.st_template,
        icon_svg=request.icon_svg,
        tags=request.tags,
    )

    block = service.add_block(block, library_id=request.library_id)
    return BlockResponse(**block.to_dict())


@router.put("/blocks/{block_id}", response_model=BlockResponse)
async def update_block(block_id: str, request: UpdateBlockRequest):
    """更新算法块"""
    from .models import BlockPort, BlockParameter, PortDirection, BlockCategory

    service = get_library_service()

    update_data = {}
    if request.name is not None:
        update_data["name"] = request.name
    if request.category is not None:
        update_data["category"] = BlockCategory(request.category)
    if request.version is not None:
        update_data["version"] = request.version
    if request.description is not None:
        update_data["description"] = request.description
    if request.author is not None:
        update_data["author"] = request.author
    if request.block_kind is not None:
        update_data["block_kind"] = request.block_kind
    if request.time_based is not None:
        update_data["time_based"] = request.time_based
    if request.signal_type is not None:
        try:
            update_data["signal_type"] = SignalType(request.signal_type)
        except ValueError:
            pass
    if request.inputs is not None:
        update_data["inputs"] = [
            BlockPort(
                name=p.name,
                direction=PortDirection(p.direction),
                data_type=p.data_type,
                description=p.description,
                default_value=p.default_value,
            )
            for p in request.inputs
        ]
    if request.outputs is not None:
        update_data["outputs"] = [
            BlockPort(
                name=p.name,
                direction=PortDirection(p.direction),
                data_type=p.data_type,
                description=p.description,
                default_value=p.default_value,
            )
            for p in request.outputs
        ]
    if request.parameters is not None:
        update_data["parameters"] = [
            BlockParameter(
                name=p.name,
                data_type=p.data_type,
                default_value=p.default_value,
                min_value=p.min_value,
                max_value=p.max_value,
                description=p.description,
            )
            for p in request.parameters
        ]
    if request.st_template is not None:
        update_data["st_template"] = request.st_template
    if request.icon_svg is not None:
        update_data["icon_svg"] = request.icon_svg
    if request.tags is not None:
        update_data["tags"] = request.tags

    block = service.update_block(block_id, **update_data)
    if not block:
        raise HTTPException(status_code=404, detail="Block not found")

    return BlockResponse(**block.to_dict())


@router.delete("/blocks/{block_id}")
async def delete_block(block_id: str):
    """删除算法块"""
    service = get_library_service()
    success = service.delete_block(block_id)
    if not success:
        raise HTTPException(status_code=404, detail="Block not found")
    return {"success": True}


# ========== Library-scoped Block Endpoints ==========

@router.get("/libraries/{library_id}/blocks", response_model=list[BlockResponse])
async def list_library_blocks(library_id: str):
    """列出指定库内的算法块"""
    service = get_library_service()
    classification = ClassificationFilter(library_id=library_id)
    blocks = service.list_blocks(classification=classification)
    return [BlockResponse(**b.to_dict()) for b in blocks]


@router.post("/libraries/{library_id}/blocks", response_model=BlockResponse)
async def create_block_in_library(library_id: str, request: CreateBlockRequest):
    """在指定库内创建算法块"""
    from .models import AlgorithmBlock, BlockPort, BlockParameter, PortDirection

    service = get_library_service()
    lib = service.get_library(library_id)
    if not lib:
        raise HTTPException(status_code=404, detail="Library not found")

    try:
        sig = SignalType(request.signal_type)
    except ValueError:
        sig = SignalType.MIXED

    block = AlgorithmBlock(
        id="",
        name=request.name,
        category=BlockCategory(request.category),
        version=request.version,
        description=request.description,
        author=request.author,
        block_kind=request.block_kind,
        time_based=request.time_based,
        signal_type=sig,
        inputs=[
            BlockPort(name=p.name, direction=PortDirection(p.direction),
                      data_type=p.data_type, description=p.description,
                      default_value=p.default_value)
            for p in request.inputs
        ],
        outputs=[
            BlockPort(name=p.name, direction=PortDirection(p.direction),
                      data_type=p.data_type, description=p.description,
                      default_value=p.default_value)
            for p in request.outputs
        ],
        parameters=[
            BlockParameter(name=p.name, data_type=p.data_type,
                           default_value=p.default_value,
                           min_value=p.min_value, max_value=p.max_value,
                           description=p.description)
            for p in request.parameters
        ],
        st_template=request.st_template,
        icon_svg=request.icon_svg,
        tags=request.tags,
    )

    block = service.add_block(block, library_id=library_id)
    return BlockResponse(**block.to_dict())


# ========== Import/Export Endpoints (JSON, backward compatible) ==========

@router.post("/import", response_model=ImportResultResponse)
async def import_block(block_data: dict):
    """导入算法块（JSON）"""
    service = get_library_service()
    result = service.import_block(block_data)
    return ImportResultResponse(**result.to_dict())


@router.post("/import/file")
async def import_block_file(file: UploadFile = File(...)):
    """从文件导入算法块"""
    content = await file.read()
    import json
    try:
        block_data = json.loads(content)
        service = get_library_service()
        result = service.import_block(block_data)
        return ImportResultResponse(**result.to_dict())
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Invalid JSON: {str(e)}")


@router.get("/export/{block_id}")
async def export_block(block_id: str):
    """导出算法块（JSON）"""
    service = get_library_service()
    block_data = service.export_block(block_id)
    if not block_data:
        raise HTTPException(status_code=404, detail="Block not found")
    return block_data


@router.get("/export/library")
async def export_library(library_id: Optional[str] = Query(None)):
    """导出算法库（JSON）"""
    service = get_library_service()
    return service.export_library(library_id)


@router.post("/import/library")
async def import_library(library_data: dict, library_id: Optional[str] = Query(None)):
    """导入算法库（JSON）"""
    service = get_library_service()
    results = service.import_library(library_data, library_id=library_id)
    return {
        "results": [r.to_dict() for r in results],
        "total": len(results),
        "success_count": sum(1 for r in results if r.success),
        "duplicate_count": sum(1 for r in results if r.is_duplicate),
    }


# ========== Library Management Endpoints ==========

@router.post("/libraries", response_model=LibraryResponse)
async def create_library(request: CreateLibraryRequest):
    """创建算法库"""
    service = get_library_service()
    library = service.create_library(
        request.name, request.description, request.owner,
        request.version, request.library_id,
    )
    return LibraryResponse(**library.to_dict())


@router.get("/libraries", response_model=list[LibraryResponse])
async def list_libraries(include_shared: bool = Query(True)):
    """列出算法库"""
    service = get_library_service()
    libraries = service.list_libraries(include_shared)
    return [LibraryResponse(**lib.to_dict()) for lib in libraries]


@router.get("/libraries/{library_id}", response_model=LibraryResponse)
async def get_library(library_id: str):
    """获取算法库信息"""
    service = get_library_service()
    library = service.get_library(library_id)
    if not library:
        raise HTTPException(status_code=404, detail="Library not found")
    return LibraryResponse(**library.to_dict())


@router.put("/libraries/{library_id}", response_model=LibraryResponse)
async def update_library(library_id: str, request: UpdateLibraryRequest):
    """更新算法库元数据"""
    service = get_library_service()
    update_data = {}
    if request.name is not None:
        update_data["name"] = request.name
    if request.description is not None:
        update_data["description"] = request.description
    if request.owner is not None:
        update_data["owner"] = request.owner
    if request.version is not None:
        update_data["version"] = request.version
    library = service.update_library(library_id, **update_data)
    if not library:
        raise HTTPException(status_code=404, detail="Library not found")
    return LibraryResponse(**library.to_dict())


@router.post("/libraries/{library_id}/share")
async def share_library(library_id: str, shared: bool = Query(True)):
    """设置算法库共享状态"""
    service = get_library_service()
    success = service.share_library(library_id, shared)
    if not success:
        raise HTTPException(status_code=404, detail="Library not found")
    return {"success": True, "shared": shared}


@router.delete("/libraries/{library_id}")
async def delete_library(library_id: str):
    """删除算法库"""
    service = get_library_service()
    success = service.delete_library(library_id)
    if not success:
        raise HTTPException(status_code=404, detail="Library not found")
    return {"success": True}


@router.post("/libraries/{library_id}/clear")
async def clear_library(library_id: str):
    """清空算法库中的所有块"""
    service = get_library_service()
    removed = service.clear_library(library_id)
    return {"success": True, "removed": removed}


@router.get("/libraries/{library_id}/validate", response_model=ValidationResponse)
async def validate_library(library_id: str):
    """验证算法库完整性"""
    service = get_library_service()
    valid, errors = service.validate_library(library_id)
    return ValidationResponse(valid=valid, errors=errors)


# ========== ZIP Import/Export ==========

@router.get("/libraries/{library_id}/export-zip")
async def export_library_zip(library_id: str):
    """导出算法库为 ZIP 文件"""
    service = get_library_service()
    lib = service.get_library(library_id)
    if not lib:
        raise HTTPException(status_code=404, detail="Library not found")

    tmp = tempfile.NamedTemporaryFile(suffix=".zip", delete=False)
    tmp_path = Path(tmp.name)
    tmp.close()
    try:
        service.export_library_zip(library_id, tmp_path)
        return FileResponse(
            tmp_path,
            media_type="application/zip",
            filename=f"{library_id}.zip",
        )
    except Exception as e:
        tmp_path.unlink(missing_ok=True)
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/libraries/import-zip", response_model=LibraryResponse)
async def import_library_zip(
    file: UploadFile = File(...),
    library_id: Optional[str] = Query(None),
):
    """从 ZIP 文件导入算法库"""
    service = get_library_service()
    content = await file.read()
    tmp = tempfile.NamedTemporaryFile(suffix=".zip", delete=False)
    tmp.write(content)
    tmp.close()
    tmp_path = Path(tmp.name)
    try:
        info = service.import_library_zip(tmp_path, library_id=library_id)
        return LibraryResponse(**info.to_dict())
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e))
    finally:
        tmp_path.unlink(missing_ok=True)
