// Shared types for the device configuration view.

export interface ChannelInfo {
  channel: number;
  var_name: string | null;
  bound: boolean;
  name: string;
  signal_type: string;
  /** State of the tree checkbox: the carrying point's `enabled` flag. */
  enabled: boolean;
}

export interface ModuleView {
  module_id: string;
  kind: string;
  first_channel: number;
  channel_count: number;
  last_channel: number;
  label: string;
  channel_list: ChannelInfo[];
}

export interface StationRow {
  station_id: string;
  label: string;
  device_type: string;
  cycle_ms: number;
  comm_interface: string;
  comm_address: string;
  modules: number;
  variables: number;
  mapped: number;
  errors: number;
  warnings: number;
}

export interface ExternalVarRow {
  name: string;
  direction: string;
  st_type: string;
  io_kind: string;
  description: string;
  enabled: boolean;
  mapped: boolean;
  channel: number | null;
  module_id: string | null;
  point_name: string;
  unit: string;
  has_quality: boolean;
  scale: number;
  bias: number;
  safety_min: number | null;
  safety_max: number | null;
  fault_hold: string;
  preset_value: number | null;
  signal_type: string;
}

export interface ValidationIssue {
  code: string;
  severity: string;
  message: string;
  var_name: string | null;
  channel: number | null;
}

export interface ValidationResult {
  ok: boolean;
  errors: ValidationIssue[];
  warnings: ValidationIssue[];
}

export interface BindingPayload {
  var_name: string;
  channel: number;
  scale: number;
  bias: number;
  safety_min: number | null;
  safety_max: number | null;
  point_name: string;
  unit: string;
  has_quality: boolean;
  fault_hold: string;
  preset_value: number | null;
  signal_type: string;
}

export const KIND_COLOR: Record<string, string> = {
  AI: "rgb(var(--ide-hue-teal))",
  AO: "rgb(var(--ide-hue-yellow))",
  DI: "rgb(var(--ide-hue-blue))",
  DO: "rgb(var(--ide-hue-purple))",
};

export const DEVICE_TYPES = ["DCU", "RPS", "ESFAS", "SIM"];

export const COMM_INTERFACES = ["backplane", "modbus_tcp", "profibus_dp", "iec61850", "none"];

export const HOLD_LABELS: Record<string, string> = {
  "": "未配置",
  last_value: "保持上周期值",
  preset: "预设值",
};

export const SIGNAL_TYPES = ["", "voltage", "current", "4-20mA", "0-5V"];

export const SIGNAL_TYPE_LABELS: Record<string, string> = {
  "": "未配置",
  voltage: "电压",
  current: "电流",
  "4-20mA": "4-20mA",
  "0-5V": "0-5V",
};

// A module kind carries direction and analogue/digital by definition, so the
// point table shows it instead of asking for those properties again.
export const IO_KIND_LABEL: Record<string, string> = {
  AI: "模拟量输入",
  AO: "模拟量输出",
  DI: "开关量输入",
  DO: "开关量输出",
};

/** The check code stays the machine key; the panel shows this label in its place. */
export const ISSUE_LABEL: Record<string, string> = {
  invalid_name: "标识符不合法",
  unknown_var: "变量未声明",
  channel_out_of_range: "通道越界",
  no_hardware: "通道无硬件",
  non_finite_cal: "量程/偏置非有限值",
  bad_safety_limit: "幅值限制倒置",
  bad_hold_mode: "异常保持方式非法",
  preset_missing: "缺少预设值",
  quality_not_in_artifact: "质量位不落制品",
  hold_not_in_artifact: "异常保持不落制品",
  duplicate_channel: "通道重复绑定",
  kind_mismatch: "模块类型不符",
  unmapped_variable: "点位未映射通道",
  duplicate_point: "点名称重复",
};

export const SEVERITY_LABEL: Record<string, string> = {
  error: "错误",
  warning: "提醒",
};

export function issueTitle(issue: ValidationIssue): string {
  return ISSUE_LABEL[issue.code] ?? issue.code;
}

export function severityLabel(severity: string): string {
  return SEVERITY_LABEL[severity] ?? severity;
}
