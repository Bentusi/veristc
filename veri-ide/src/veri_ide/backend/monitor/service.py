"""
在线监视与调试服务

提供功能：
- 变量实时监视（单个/批量）
- 变量强制（Force）与释放（Release）
- 参数在线修改
- 监视表管理
- 批量操作支持
"""

import uuid
from datetime import datetime
from typing import Optional, Any

from .models import (
    VariableInfo,
    VariableType,
    DataType,
    ForceStatus,
    ForceRequest,
    ForceResult,
    WatchEntry,
    ParameterModification,
    MonitorSnapshot,
    BatchOperation,
    MonitorMode,
)


class MonitorService:
    """在线监视服务"""
    
    def __init__(self):
        # TODO: 后续替换为与 VM 的真实通信
        self._variables: dict[str, VariableInfo] = {}
        self._watch_table: dict[str, WatchEntry] = {}
        self._modifications: list[ParameterModification] = []
        self._batch_operations: dict[str, BatchOperation] = {}
        self._cycle_count: int = 0
        
        # 初始化一些示例变量
        self._init_sample_variables()
    
    def _init_sample_variables(self):
        """初始化示例变量（演示用）"""
        sample_vars = [
            ("SP", 4096, DataType.REAL, VariableType.INPUT, 50.0),
            ("PV", 4100, DataType.REAL, VariableType.INPUT, 45.5),
            ("OUT", 4104, DataType.REAL, VariableType.OUTPUT, 60.0),
            ("PID1_Kp", 4108, DataType.REAL, VariableType.LOCAL, 2.5),
            ("PID1_Ti", 4112, DataType.REAL, VariableType.LOCAL, 100.0),
            ("PID1_Td", 4116, DataType.REAL, VariableType.LOCAL, 10.0),
            ("START", 4120, DataType.BOOL, VariableType.INPUT, True),
            ("STOP", 4124, DataType.BOOL, VariableType.INPUT, False),
            ("ALARM", 4128, DataType.BOOL, VariableType.OUTPUT, False),
        ]
        
        for name, addr, dtype, vtype, value in sample_vars:
            self._variables[name] = VariableInfo(
                name=name,
                address=addr,
                data_type=dtype,
                var_type=vtype,
                current_value=value,
            )
    
    # ========== 变量监视 ==========
    
    def get_variable(self, name: str) -> Optional[VariableInfo]:
        """获取单个变量信息"""
        return self._variables.get(name)
    
    def get_variables(self, names: list[str]) -> list[VariableInfo]:
        """批量获取变量信息"""
        return [self._variables[name] for name in names if name in self._variables]
    
    def list_variables(
        self,
        var_type: Optional[VariableType] = None,
        data_type: Optional[DataType] = None,
        force_status: Optional[ForceStatus] = None,
    ) -> list[VariableInfo]:
        """列出变量（支持过滤）"""
        result = list(self._variables.values())
        
        if var_type:
            result = [v for v in result if v.var_type == var_type]
        if data_type:
            result = [v for v in result if v.data_type == data_type]
        if force_status:
            result = [v for v in result if v.force_status == force_status]
        
        return result
    
    def take_snapshot(self, variable_names: Optional[list[str]] = None) -> MonitorSnapshot:
        """获取监视数据快照"""
        if variable_names:
            variables = self.get_variables(variable_names)
        else:
            variables = list(self._variables.values())
        
        self._cycle_count += 1
        
        return MonitorSnapshot(
            timestamp=datetime.now(),
            cycle_count=self._cycle_count,
            variables=variables,
        )
    
    # ========== 变量强制 ==========
    
    def force_variable(self, request: ForceRequest) -> ForceResult:
        """强制变量值"""
        var = self._variables.get(request.variable_name)
        if not var:
            return ForceResult(
                success=False,
                variable_name=request.variable_name,
                message=f"变量不存在: {request.variable_name}",
            )
        
        # 验证值类型
        if not self._validate_value(request.force_value, request.data_type):
            return ForceResult(
                success=False,
                variable_name=request.variable_name,
                message=f"值类型不匹配: 期望 {request.data_type.value}",
            )
        
        # 应用强制
        var.forced_value = request.force_value
        var.force_status = ForceStatus.FORCED
        var.last_updated = datetime.now()
        
        return ForceResult(
            success=True,
            variable_name=request.variable_name,
            message=f"变量已强制: {request.force_value}",
            effective_at=datetime.now(),
        )
    
    def release_variable(self, variable_name: str) -> ForceResult:
        """释放变量强制"""
        var = self._variables.get(variable_name)
        if not var:
            return ForceResult(
                success=False,
                variable_name=variable_name,
                message=f"变量不存在: {variable_name}",
            )
        
        if var.force_status == ForceStatus.NOT_FORCED:
            return ForceResult(
                success=False,
                variable_name=variable_name,
                message="变量未被强制",
            )
        
        var.forced_value = None
        var.force_status = ForceStatus.NOT_FORCED
        var.last_updated = datetime.now()
        
        return ForceResult(
            success=True,
            variable_name=variable_name,
            message="变量强制已释放",
        )
    
    def force_batch(self, requests: list[ForceRequest]) -> BatchOperation:
        """批量强制变量"""
        batch_id = str(uuid.uuid4())
        batch = BatchOperation(
            id=batch_id,
            operation_type="force",
            items=[r.to_dict() for r in requests],
        )
        
        results = []
        for request in requests:
            result = self.force_variable(request)
            results.append(result.to_dict())
            if result.success:
                batch.success_count += 1
            else:
                batch.failure_count += 1
        
        batch.results = results
        batch.completed_at = datetime.now()
        self._batch_operations[batch_id] = batch
        
        return batch
    
    def release_batch(self, variable_names: list[str]) -> BatchOperation:
        """批量释放变量强制"""
        batch_id = str(uuid.uuid4())
        batch = BatchOperation(
            id=batch_id,
            operation_type="release",
            items=[{"variable_name": name} for name in variable_names],
        )
        
        results = []
        for name in variable_names:
            result = self.release_variable(name)
            results.append(result.to_dict())
            if result.success:
                batch.success_count += 1
            else:
                batch.failure_count += 1
        
        batch.results = results
        batch.completed_at = datetime.now()
        self._batch_operations[batch_id] = batch
        
        return batch
    
    def _validate_value(self, value: Any, data_type: DataType) -> bool:
        """验证值类型"""
        try:
            if data_type == DataType.BOOL:
                return isinstance(value, bool)
            elif data_type in (DataType.INT, DataType.DINT):
                return isinstance(value, int)
            elif data_type == DataType.REAL:
                return isinstance(value, (int, float))
            elif data_type == DataType.STRING:
                return isinstance(value, str)
            return True
        except Exception:
            return False
    
    # ========== 参数修改 ==========
    
    def modify_parameter(
        self,
        block_id: str,
        parameter_name: str,
        new_value: Any,
        data_type: DataType,
    ) -> ParameterModification:
        """修改功能块参数"""
        # TODO: 与 VM 通信，实际应用参数修改
        var_name = f"{block_id}_{parameter_name}"
        var = self._variables.get(var_name)
        
        modification = ParameterModification(
            block_id=block_id,
            parameter_name=parameter_name,
            old_value=var.current_value if var else None,
            new_value=new_value,
            data_type=data_type,
        )
        
        if not self._validate_value(new_value, data_type):
            modification.error = f"值类型不匹配: 期望 {data_type.value}"
            self._modifications.append(modification)
            return modification
        
        # 应用修改
        if var:
            var.current_value = new_value
            var.last_updated = datetime.now()
            modification.applied = True
        else:
            # 创建新变量（如果不存在）
            self._variables[var_name] = VariableInfo(
                name=var_name,
                address=0,  # TODO: 分配真实地址
                data_type=data_type,
                var_type=VariableType.LOCAL,
                current_value=new_value,
            )
            modification.applied = True
        
        self._modifications.append(modification)
        return modification
    
    def modify_batch(self, modifications: list[dict]) -> BatchOperation:
        """批量修改参数"""
        batch_id = str(uuid.uuid4())
        batch = BatchOperation(
            id=batch_id,
            operation_type="modify",
            items=modifications,
        )
        
        results = []
        for mod in modifications:
            result = self.modify_parameter(
                block_id=mod["block_id"],
                parameter_name=mod["parameter_name"],
                new_value=mod["new_value"],
                data_type=DataType(mod["data_type"]),
            )
            results.append(result.to_dict())
            if result.applied:
                batch.success_count += 1
            else:
                batch.failure_count += 1
        
        batch.results = results
        batch.completed_at = datetime.now()
        self._batch_operations[batch_id] = batch
        
        return batch
    
    def get_modification_history(self, limit: int = 100) -> list[ParameterModification]:
        """获取参数修改历史"""
        return self._modifications[-limit:]
    
    # ========== 监视表管理 ==========
    
    def add_watch_entry(self, variable_name: str, alias: Optional[str] = None) -> WatchEntry:
        """添加监视表条目"""
        entry_id = str(uuid.uuid4())
        entry = WatchEntry(
            id=entry_id,
            variable_name=variable_name,
            alias=alias,
        )
        self._watch_table[entry_id] = entry
        return entry
    
    def remove_watch_entry(self, entry_id: str) -> bool:
        """移除监视表条目"""
        if entry_id in self._watch_table:
            del self._watch_table[entry_id]
            return True
        return False
    
    def get_watch_table(self) -> list[WatchEntry]:
        """获取监视表"""
        return list(self._watch_table.values())
    
    def update_watch_entry(self, entry_id: str, **kwargs) -> Optional[WatchEntry]:
        """更新监视表条目"""
        entry = self._watch_table.get(entry_id)
        if not entry:
            return None
        
        for key, value in kwargs.items():
            if hasattr(entry, key):
                setattr(entry, key, value)
        
        return entry
    
    def get_watch_snapshot(self) -> MonitorSnapshot:
        """获取监视表快照"""
        variables = []
        for entry in self._watch_table.values():
            if entry.enabled:
                var = self._variables.get(entry.variable_name)
                if var:
                    entry.last_value = var.current_value
                    entry.last_update = datetime.now()
                    variables.append(var)
        
        self._cycle_count += 1
        
        return MonitorSnapshot(
            timestamp=datetime.now(),
            cycle_count=self._cycle_count,
            variables=variables,
        )
    
    # ========== 批量操作查询 ==========
    
    def get_batch_operation(self, batch_id: str) -> Optional[BatchOperation]:
        """获取批量操作状态"""
        return self._batch_operations.get(batch_id)
    
    def list_batch_operations(self, limit: int = 50) -> list[BatchOperation]:
        """列出批量操作历史"""
        return list(self._batch_operations.values())[-limit:]


# 全局服务实例
_service: Optional[MonitorService] = None


def get_monitor_service() -> MonitorService:
    """获取监视服务实例"""
    global _service
    if _service is None:
        _service = MonitorService()
    return _service
