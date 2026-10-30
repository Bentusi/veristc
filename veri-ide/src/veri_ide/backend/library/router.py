"""
算法块与算法库 API 路由

端点：
- 算法块 CRUD
- 算法库管理
- 导入/导出
- 共享库支持
"""

from fastapi import APIRouter, HTTPException, Query, UploadFile, File
from pydantic import BaseModel
from typing import Optional, Any

from .service import get_library_service
from .models import BlockCategory


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
    inputs: list[BlockPortRequest] = []
    outputs: list[BlockPortRequest] = []
    parameters: list[BlockParameterRequest] = []
    st_template: str = ""
    icon_svg: str = ""
    tags: list[str] = []


class UpdateBlockRequest(BaseModel):
    name: Optional[str] = None
    description: Optional[str] = None
    block_kind: Optional[str] = None
    time_based: Optional[bool] = None
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
    inputs: list[dict]
    outputs: list[dict]
    parameters: list[dict]
    st_template: str
    icon_svg: str
    tags: list[str]
    sha256: str


class LibraryResponse(BaseModel):
    id: str
    name: str
    description: str
    owner: str
    is_shared: bool
    blocks_count: int
    created_at: str
    updated_at: str


class ImportResultResponse(BaseModel):
    success: bool
    block_id: str = ""
    message: str = ""
    is_duplicate: bool = False


class CreateLibraryRequest(BaseModel):
    name: str
    description: str = ""


# ========== Block Endpoints ==========

@router.get("/blocks", response_model=list[BlockResponse])
async def list_blocks(
    category: Optional[str] = Query(None),
    search: Optional[str] = Query(None),
    tag: Optional[str] = Query(None),
):
    """列出算法块"""
    service = get_library_service()
    
    cat = BlockCategory(category) if category else None
    blocks = service.list_blocks(cat, search, tag)
    
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
    
    block = AlgorithmBlock(
        id="",
        name=request.name,
        category=BlockCategory(request.category),
        version=request.version,
        description=request.description,
        author=request.author,
        block_kind=request.block_kind,
        time_based=request.time_based,
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
    
    block = service.add_block(block)
    return BlockResponse(**block.to_dict())


@router.put("/blocks/{block_id}", response_model=BlockResponse)
async def update_block(block_id: str, request: UpdateBlockRequest):
    """更新算法块"""
    service = get_library_service()
    
    update_data = {}
    if request.name is not None:
        update_data["name"] = request.name
    if request.description is not None:
        update_data["description"] = request.description
    if request.block_kind is not None:
        update_data["block_kind"] = request.block_kind
    if request.time_based is not None:
        update_data["time_based"] = request.time_based
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


# ========== Import/Export Endpoints ==========

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
async def export_library():
    """导出整个算法库"""
    service = get_library_service()
    return service.export_library()


@router.post("/import/library")
async def import_library(library_data: dict):
    """导入算法库"""
    service = get_library_service()
    results = service.import_library(library_data)
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
    library = service.create_library(request.name, request.description)
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
