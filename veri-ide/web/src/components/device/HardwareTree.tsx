import { useState } from "react";
import { IO_KIND_LABEL, KIND_COLOR, type ModuleView } from "./types";
import { ContextMenu, type ContextMenuItem } from "../ContextMenu";
import { useI18n } from "../../lib/i18n";

interface HardwareTreeProps {
  modules: ModuleView[];
  selectedChannel: number | null;
  onSelectChannel: (channel: number) => void;
  collapsed: Record<string, boolean>;
  onToggle: (moduleId: string) => void;
  onUpdateChannelName: (moduleId: string, channel: number, name: string) => void;
  onAddModule?: (kind: string) => void;
  onRemoveModule?: (moduleId: string) => void;
  /** Only a channel whose point was deleted can lack one: re-create variable + binding. */
  onCreatePoint?: (moduleId: string, channel: number) => void;
  onDeletePoint?: (varName: string) => void;
  /** Disable / enable the point a channel carries; the tree checkbox. */
  onToggleEnabled?: (varName: string, enabled: boolean) => void;
}

export function HardwareTree({
  modules,
  selectedChannel,
  onSelectChannel,
  collapsed,
  onToggle,
  onUpdateChannelName,
  onAddModule,
  onRemoveModule,
  onCreatePoint,
  onDeletePoint,
  onToggleEnabled,
}: HardwareTreeProps) {
  const { t } = useI18n();
  const [editingChannel, setEditingChannel] = useState<{ moduleId: string; channel: number } | null>(null);
  const [editValue, setEditValue] = useState("");
  const [contextMenu, setContextMenu] = useState<{
    x: number;
    y: number;
    moduleId?: string;
    channel?: number;
  } | null>(null);

  const pointCount = modules.reduce(
    (total, m) => total + m.channel_list.filter((c) => c.bound).length,
    0,
  );
  const channelCount = modules.reduce((total, m) => total + m.channel_count, 0);

  const startEditing = (moduleId: string, channel: number, currentName: string) => {
    setEditingChannel({ moduleId, channel });
    setEditValue(currentName);
  };

  const commitEdit = () => {
    if (editingChannel) {
      onUpdateChannelName(editingChannel.moduleId, editingChannel.channel, editValue);
      setEditingChannel(null);
      setEditValue("");
    }
  };

  const cancelEdit = () => {
    setEditingChannel(null);
    setEditValue("");
  };

  const handleContextMenu = (event: React.MouseEvent, moduleId?: string, channel?: number) => {
    event.preventDefault();
    event.stopPropagation();
    setContextMenu({ x: event.clientX, y: event.clientY, moduleId, channel });
  };

  const getContextMenuItems = (): ContextMenuItem[] => {
    if (contextMenu?.channel !== undefined && contextMenu.moduleId) {
      const module = modules.find((m) => m.module_id === contextMenu.moduleId);
      const channelInfo = module?.channel_list.find((c) => c.channel === contextMenu.channel);
      const varName = channelInfo?.var_name ?? null;
      const channel = contextMenu.channel;
      const items: ContextMenuItem[] = [];

      if (varName === null) {
        items.push({
          label: `${t("hwTree.createPoint")} ${channel} ${t("hwTree.createPoint2")}`,
          onClick: () => onCreatePoint?.(contextMenu.moduleId!, channel),
        });
      } else {
        items.push({
          label: channelInfo?.enabled ? `${t("hwTree.disablePoint")} ${varName}` : `${t("hwTree.enablePoint")} ${varName}`,
          onClick: () => onToggleEnabled?.(varName, !(channelInfo?.enabled ?? true)),
        });
        items.push({ label: `${t("hwTree.deletePoint")} ${varName}`, onClick: () => onDeletePoint?.(varName) });
      }

      items.push({ separator: true, label: "", onClick: () => {} });
      items.push({
        label: t("hwTree.renameChannel"),
        onClick: () => startEditing(contextMenu.moduleId!, channel, channelInfo?.name ?? ""),
      });

      return items;
    } else if (contextMenu?.moduleId) {
      // Right-clicked on a module header
      return [
        {
          label: `${t("hwTree.deleteModule")} ${contextMenu.moduleId}`,
          onClick: () => onRemoveModule?.(contextMenu.moduleId!),
        },
      ];
    } else {
      // Right-clicked on empty space
      return [
        { label: t("hwTree.addAI"), onClick: () => onAddModule?.("AI") },
        { label: t("hwTree.addAO"), onClick: () => onAddModule?.("AO") },
        { label: t("hwTree.addDI"), onClick: () => onAddModule?.("DI") },
        { label: t("hwTree.addDO"), onClick: () => onAddModule?.("DO") },
      ];
    }
  };

  return (
    <div
      className="w-60 bg-ide-sidebar border-r border-ide-border flex flex-col overflow-hidden"
      onContextMenu={(e) => handleContextMenu(e)}
    >
      <div className="px-3 py-2 border-b border-ide-border">
        <div className="text-xs font-semibold uppercase text-ide-textDim">{t("hwTree.hardwareChannels")}</div>
        <div className="text-[10px] text-ide-textDim mt-1">
          {modules.length} {t("hwTree.modules")} · {pointCount}/{channelCount} {t("hwTree.channelsWithPoints")}
        </div>
      </div>

      <div className="flex-1 overflow-y-auto py-1">
        {modules.map((module) => {
          const points = module.channel_list.filter((c) => c.bound).length;
          const open = !collapsed[module.module_id];
          return (
            <div key={module.module_id}>
              <button
                onClick={() => onToggle(module.module_id)}
                onContextMenu={(e) => handleContextMenu(e, module.module_id)}
                title={`${IO_KIND_LABEL[module.kind] ?? module.kind}: ${t("device.directionHint")}`}
                className="w-full px-3 py-1.5 flex items-center gap-1.5 text-xs hover:bg-ide-hover"
              >
                <svg
                  viewBox="0 0 24 24"
                  className={`w-3 h-3 text-ide-textDim transition-transform ${open ? "rotate-90" : ""}`}
                  fill="currentColor"
                >
                  <path d="M10 17l5-5-5-5v10z" />
                </svg>
                <span
                  className="w-2 h-2 rounded-full shrink-0"
                  style={{ backgroundColor: KIND_COLOR[module.kind] }}
                />
                <span className="font-mono">{module.module_id}</span>
                <span className="text-ide-textDim">
                  {module.kind} {module.first_channel}–{module.last_channel}
                </span>
                <span className="flex-1" />
                <span
                  className={`text-[10px] ${points === 0 ? "text-ide-textDim" : "text-ide-accent"}`}
                >
                  {points}/{module.channel_count} {t("hwTree.points")}
                </span>
              </button>

              {open && (
                <div className="pb-1">
                  {module.channel_list.map((channel) => {
                    const isEditing = editingChannel?.moduleId === module.module_id && editingChannel?.channel === channel.channel;
                    const owner = channel.var_name;
                    return (
                      <button
                        key={channel.channel}
                        onClick={() => !isEditing && onSelectChannel(channel.channel)}
                        onContextMenu={(e) => handleContextMenu(e, module.module_id, channel.channel)}
                        className={`w-full pl-6 pr-3 py-1 flex items-center gap-2 text-xs ${
                          selectedChannel === channel.channel
                            ? "bg-ide-selected text-ide-strong"
                            : "hover:bg-ide-hover text-ide-text"
                        } ${channel.enabled ? "" : "opacity-40"}`}
                      >
                        <span
                          role="checkbox"
                          aria-checked={channel.enabled && !!owner}
                          aria-label={`CH${channel.channel} ${t("hwTree.points")}`}
                          data-testid={`tree-enabled-${module.module_id}-${channel.channel}`}
                          onClick={(e) => {
                            e.stopPropagation();
                            if (owner && onToggleEnabled) onToggleEnabled(owner, !channel.enabled);
                          }}
                          className={`w-3 h-3 shrink-0 rounded-sm border flex items-center justify-center ${
                            owner && onToggleEnabled
                              ? "cursor-pointer border-ide-textDim"
                              : "cursor-default border-ide-border"
                          } ${channel.enabled && owner ? "bg-emerald-500 border-emerald-500" : ""}`}
                          title={
                            owner
                              ? channel.enabled
                                ? t("hwTree.disableChannel")
                                : t("hwTree.enableChannel")
                              : t("hwTree.noPointYet")
                          }
                        >
                          {channel.enabled && owner && (
                            <svg viewBox="0 0 24 24" className="w-2.5 h-2.5 text-white" fill="none" stroke="currentColor" strokeWidth="3">
                              <path d="M5 13l4 4L19 7" />
                            </svg>
                          )}
                        </span>
                        <span
                          className={`w-1.5 h-1.5 rounded-full ${
                            channel.bound ? "bg-green-500" : "bg-ide-border"
                          }`}
                        />
                        <span className="font-mono">CH{channel.channel}</span>
                        {isEditing ? (
                          <input
                            type="text"
                            value={editValue}
                            onChange={(e) => setEditValue(e.target.value)}
                            onBlur={commitEdit}
                            onKeyDown={(e) => {
                              if (e.key === "Enter") commitEdit();
                              if (e.key === "Escape") cancelEdit();
                            }}
                            onClick={(e) => e.stopPropagation()}
                            className="flex-1 bg-ide-bg border border-ide-border rounded px-1 py-0.5 text-xs font-mono min-w-0"
                            placeholder={t("hwTree.channelName")}
                            autoFocus
                          />
                        ) : (
                          <>
                            {channel.name ? (
                              <span
                                className="text-ide-textDim truncate max-w-20 cursor-text"
                                onDoubleClick={(e) => {
                                  e.stopPropagation();
                                  startEditing(module.module_id, channel.channel, channel.name);
                                }}
                                title={t("hwTree.editName")}
                              >
                                {channel.name}
                              </span>
                            ) : (
                              <span
                                className="text-ide-textDim italic cursor-text"
                                onDoubleClick={(e) => {
                                  e.stopPropagation();
                                  startEditing(module.module_id, channel.channel, "");
                                }}
                                title={t("hwTree.addName")}
                              >
                                {t("hwTree.unnamed")}
                              </span>
                            )}
                          </>
                        )}
                        <span className="flex-1" />
                        {channel.var_name ? (
                          <span className="text-ide-accent truncate max-w-24">{channel.var_name}</span>
                        ) : (
                          <span className="text-ide-textDim">{t("hwTree.noPoints")}</span>
                        )}
                      </button>
                    );
                  })}
                </div>
              )}
            </div>
          );
        })}

        {modules.length === 0 && (
          <div className="px-3 py-4 text-xs text-ide-textDim">{t("hwTree.notConfigured")}</div>
        )}
      </div>

      {contextMenu && (
        <ContextMenu
          x={contextMenu.x}
          y={contextMenu.y}
          items={getContextMenuItems()}
          onClose={() => setContextMenu(null)}
        />
      )}
    </div>
  );
}
