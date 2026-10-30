// Shared types for the device configuration view.

export interface ChannelInfo {
  channel: number;
  var_name: string | null;
  bound: boolean;
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

export interface MappingRow {
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
  direction: string | null;
  st_type: string | null;
  derived_kind: string | null;
  module_id: string | null;
  module_kind: string | null;
  kind_match: boolean;
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
}

export interface IoVariable {
  name: string;
  direction: string;
  st_type: string;
  io_kind: string;
  description: string;
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
}

export const KIND_COLOR: Record<string, string> = {
  AI: "#4ec9b0",
  AO: "#dcdcaa",
  DI: "#569cd6",
  DO: "#c586c0",
};

export const DEVICE_TYPES = ["DCU", "RPS", "ESFAS", "SIM"];

export const COMM_INTERFACES = ["backplane", "modbus_tcp", "profibus_dp", "iec61850", "none"];

export const HOLD_LABELS: Record<string, string> = {
  "": "未配置",
  last_value: "保持上周期值",
  preset: "预设值",
};
