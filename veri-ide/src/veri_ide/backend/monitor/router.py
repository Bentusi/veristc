"""
在线监视与调试 API 路由

端点：
- 变量监视（单个/批量）
- 变量强制与释放
- 参数修改
- 监视表管理
- 批量操作
"""

from fastapi import APIRouter, HTTPException, Query
from pydantic import BaseModel
from typing import Optional, Any

from .service import get_monitor_service
from .models import (
    VariableType,
    DataType,
    ForceStatus,
    ForceRequest,
    MonitorMode,
)


router = APIRouter(prefix="/monitor", tags=["monitor"])


# ========== Request/Response Models ==========

class VariableResponse(BaseModel):
    name: str
    address: int
    data_type: str
    var_type: str
    current_value: Any
    forced_value: Optional[Any]
    force_status: str
    last_updated: str
    quality: str


class ForceVariableRequest(BaseModel):
    variable_name: str
    force_value: Any
    data_type: str
    persistent: bool = False


class ForceResponse(BaseModel):
    success: bool
    variable_name: str
    message: str
    effective_at: Optional[str]


class ModifyParameterRequest(BaseModel):
    block_id: str
    parameter_name: str
    new_value: Any
    data_type: str


class ModificationResponse(BaseModel):
    block_id: str
    parameter_name: str
    old_value: Any
    new_value: Any
    data_type: str
    timestamp: str
    applied: bool
    error: Optional[str]


class WatchEntryRequest(BaseModel):
    variable_name: str
    alias: Optional[str] = None
    display_format: str = "decimal"


class WatchEntryResponse(BaseModel):
    id: str
    variable_name: str
    alias: Optional[str]
    display_format: str
    enabled: bool
    last_value: Any
    last_update: Optional[str]


class SnapshotResponse(BaseModel):
    timestamp: str
    cycle_count: int
    variables: list[VariableResponse]


class BatchOperationResponse(BaseModel):
    id: str
    operation_type: str
    items: list[dict]
    created_at: str
    completed_at: Optional[str]
    success_count: int
    failure_count: int
    results: list[dict]


# ========== Variable Monitoring Endpoints ==========

@router.get("/variables/{name}", response_model=VariableResponse)
async def get_variable(name: str):
    """获取单个变量信息"""
    service = get_monitor_service()
    var = service.get_variable(name)
    if not var:
        raise HTTPException(status_code=404, detail=f"Variable not found: {name}")
    return VariableResponse(**var.to_dict())


@router.get("/variables", response_model=list[VariableResponse])
async def list_variables(
    var_type: Optional[str] = Query(None),
    data_type: Optional[str] = Query(None),
    force_status: Optional[str] = Query(None),
):
    """列出变量（支持过滤）"""
    service = get_monitor_service()
    
    vtype = VariableType(var_type) if var_type else None
    dtype = DataType(data_type) if data_type else None
    fstatus = ForceStatus(force_status) if force_status else None
    
    variables = service.list_variables(vtype, dtype, fstatus)
    return [VariableResponse(**v.to_dict()) for v in variables]


@router.post("/variables/batch", response_model=list[VariableResponse])
async def get_variables_batch(names: list[str]):
    """批量获取变量信息"""
    service = get_monitor_service()
    variables = service.get_variables(names)
    return [VariableResponse(**v.to_dict()) for v in variables]


@router.get("/snapshot", response_model=SnapshotResponse)
async def get_snapshot(variables: Optional[str] = Query(None)):
    """获取监视数据快照"""
    service = get_monitor_service()
    
    var_names = variables.split(",") if variables else None
    snapshot = service.take_snapshot(var_names)
    
    return SnapshotResponse(
        timestamp=snapshot.timestamp.isoformat(),
        cycle_count=snapshot.cycle_count,
        variables=[VariableResponse(**v.to_dict()) for v in snapshot.variables],
    )


# ========== Force/Release Endpoints ==========

@router.post("/force", response_model=ForceResponse)
async def force_variable(request: ForceVariableRequest):
    """强制变量值"""
    service = get_monitor_service()
    
    force_req = ForceRequest(
        variable_name=request.variable_name,
        force_value=request.force_value,
        data_type=DataType(request.data_type),
        persistent=request.persistent,
    )
    
    result = service.force_variable(force_req)
    
    return ForceResponse(
        success=result.success,
        variable_name=result.variable_name,
        message=result.message,
        effective_at=result.effective_at.isoformat() if result.effective_at else None,
    )


@router.post("/release/{variable_name}", response_model=ForceResponse)
async def release_variable(variable_name: str):
    """释放变量强制"""
    service = get_monitor_service()
    result = service.release_variable(variable_name)
    
    return ForceResponse(
        success=result.success,
        variable_name=result.variable_name,
        message=result.message,
        effective_at=result.effective_at.isoformat() if result.effective_at else None,
    )


@router.post("/force/batch", response_model=BatchOperationResponse)
async def force_batch(requests: list[ForceVariableRequest]):
    """批量强制变量"""
    service = get_monitor_service()
    
    force_reqs = [
        ForceRequest(
            variable_name=r.variable_name,
            force_value=r.force_value,
            data_type=DataType(r.data_type),
            persistent=r.persistent,
        )
        for r in requests
    ]
    
    batch = service.force_batch(force_reqs)
    
    return BatchOperationResponse(
        id=batch.id,
        operation_type=batch.operation_type,
        items=batch.items,
        created_at=batch.created_at.isoformat(),
        completed_at=batch.completed_at.isoformat() if batch.completed_at else None,
        success_count=batch.success_count,
        failure_count=batch.failure_count,
        results=batch.results,
    )


@router.post("/release/batch", response_model=BatchOperationResponse)
async def release_batch(variable_names: list[str]):
    """批量释放变量强制"""
    service = get_monitor_service()
    batch = service.release_batch(variable_names)
    
    return BatchOperationResponse(
        id=batch.id,
        operation_type=batch.operation_type,
        items=batch.items,
        created_at=batch.created_at.isoformat(),
        completed_at=batch.completed_at.isoformat() if batch.completed_at else None,
        success_count=batch.success_count,
        failure_count=batch.failure_count,
        results=batch.results,
    )


# ========== Parameter Modification Endpoints ==========

@router.post("/modify", response_model=ModificationResponse)
async def modify_parameter(request: ModifyParameterRequest):
    """修改功能块参数"""
    service = get_monitor_service()
    
    result = service.modify_parameter(
        block_id=request.block_id,
        parameter_name=request.parameter_name,
        new_value=request.new_value,
        data_type=DataType(request.data_type),
    )
    
    return ModificationResponse(**result.to_dict())


@router.post("/modify/batch", response_model=BatchOperationResponse)
async def modify_batch(modifications: list[ModifyParameterRequest]):
    """批量修改参数"""
    service = get_monitor_service()
    
    mods = [
        {
            "block_id": m.block_id,
            "parameter_name": m.parameter_name,
            "new_value": m.new_value,
            "data_type": m.data_type,
        }
        for m in modifications
    ]
    
    batch = service.modify_batch(mods)
    
    return BatchOperationResponse(
        id=batch.id,
        operation_type=batch.operation_type,
        items=batch.items,
        created_at=batch.created_at.isoformat(),
        completed_at=batch.completed_at.isoformat() if batch.completed_at else None,
        success_count=batch.success_count,
        failure_count=batch.failure_count,
        results=batch.results,
    )


@router.get("/modifications", response_model=list[ModificationResponse])
async def get_modification_history(limit: int = Query(100)):
    """获取参数修改历史"""
    service = get_monitor_service()
    modifications = service.get_modification_history(limit)
    return [ModificationResponse(**m.to_dict()) for m in modifications]


# ========== Watch Table Endpoints ==========

@router.post("/watch", response_model=WatchEntryResponse)
async def add_watch_entry(request: WatchEntryRequest):
    """添加监视表条目"""
    service = get_monitor_service()
    entry = service.add_watch_entry(request.variable_name, request.alias)
    entry.display_format = request.display_format
    
    return WatchEntryResponse(**entry.to_dict())


@router.delete("/watch/{entry_id}")
async def remove_watch_entry(entry_id: str):
    """移除监视表条目"""
    service = get_monitor_service()
    success = service.remove_watch_entry(entry_id)
    if not success:
        raise HTTPException(status_code=404, detail="Watch entry not found")
    return {"success": True}


@router.get("/watch", response_model=list[WatchEntryResponse])
async def get_watch_table():
    """获取监视表"""
    service = get_monitor_service()
    entries = service.get_watch_table()
    return [WatchEntryResponse(**e.to_dict()) for e in entries]


@router.put("/watch/{entry_id}", response_model=WatchEntryResponse)
async def update_watch_entry(entry_id: str, request: WatchEntryRequest):
    """更新监视表条目"""
    service = get_monitor_service()
    entry = service.update_watch_entry(
        entry_id,
        variable_name=request.variable_name,
        alias=request.alias,
        display_format=request.display_format,
    )
    if not entry:
        raise HTTPException(status_code=404, detail="Watch entry not found")
    return WatchEntryResponse(**entry.to_dict())


@router.get("/watch/snapshot", response_model=SnapshotResponse)
async def get_watch_snapshot():
    """获取监视表快照"""
    service = get_monitor_service()
    snapshot = service.get_watch_snapshot()
    
    return SnapshotResponse(
        timestamp=snapshot.timestamp.isoformat(),
        cycle_count=snapshot.cycle_count,
        variables=[VariableResponse(**v.to_dict()) for v in snapshot.variables],
    )


# ========== Batch Operation Query ==========

@router.get("/batch/{batch_id}", response_model=BatchOperationResponse)
async def get_batch_operation(batch_id: str):
    """获取批量操作状态"""
    service = get_monitor_service()
    batch = service.get_batch_operation(batch_id)
    if not batch:
        raise HTTPException(status_code=404, detail="Batch operation not found")
    
    return BatchOperationResponse(
        id=batch.id,
        operation_type=batch.operation_type,
        items=batch.items,
        created_at=batch.created_at.isoformat(),
        completed_at=batch.completed_at.isoformat() if batch.completed_at else None,
        success_count=batch.success_count,
        failure_count=batch.failure_count,
        results=batch.results,
    )


@router.get("/batch", response_model=list[BatchOperationResponse])
async def list_batch_operations(limit: int = Query(50)):
    """列出批量操作历史"""
    service = get_monitor_service()
    batches = service.list_batch_operations(limit)
    
    return [
        BatchOperationResponse(
            id=batch.id,
            operation_type=batch.operation_type,
            items=batch.items,
            created_at=batch.created_at.isoformat(),
            completed_at=batch.completed_at.isoformat() if batch.completed_at else None,
            success_count=batch.success_count,
            failure_count=batch.failure_count,
            results=batch.results,
        )
        for batch in batches
    ]
