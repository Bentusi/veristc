import { useEffect, useState } from 'react';
import { useLocation, useNavigate } from 'react-router-dom';
import { useProject } from '../project/ProjectProvider';
import { useI18n } from '../lib/i18n';
import { toast } from './ui';

interface StageStatus {
  id: string;
  labelKey: string;
  path: string;
  complete: boolean;
  progress: number; // 0-100
}

const STAGES = [
  { id: 'device', labelKey: 'workflow.device' as const, path: '/device' },
  { id: 'graph', labelKey: 'workflow.graph' as const, path: '/graph' },
  { id: 'simulation', labelKey: 'workflow.sim' as const, path: '/simulation' },
  { id: 'download', labelKey: 'workflow.download' as const, path: '/download' },
];

export function WorkflowProgress() {
  const { t } = useI18n();
  const location = useLocation();
  const navigate = useNavigate();
  const { current } = useProject();
  const [stages, setStages] = useState<StageStatus[]>(
    STAGES.map((s) => ({ ...s, complete: false, progress: 0 })),
  );

  // Calculate stage completion based on API data
  useEffect(() => {
    if (!current) return;

    const calculateProgress = async () => {
      try {
        // Fetch device stage progress
        const stations = await fetch('http://localhost:8000/device/stations').then((r) => r.json());
        const deviceComplete = stations.length > 0;
        let deviceProgress = 0;
        if (deviceComplete) {
          const stationId = stations[0].station_id;
          const mappings = await fetch(
            `http://localhost:8000/device/stations/${stationId}/mappings`,
          ).then((r) => r.json());
          const variables = await fetch(
            `http://localhost:8000/device/stations/${stationId}/variables`,
          ).then((r) => r.json());
          const boundCount = mappings.length;
          const totalCount = variables.length;
          deviceProgress = totalCount > 0 ? Math.round((boundCount / totalCount) * 100) : 0;
        }

        // Fetch graph stage progress
        const pages = await fetch('http://localhost:8000/graph/pages').then((r) => r.json());
        const graphComplete = pages.length > 0;
        const graphProgress = graphComplete ? 100 : 0;

        // Check simulation stage (has run at least one simulation)
        const simComplete = false;
        const simProgress = 0;

        // Check download stage (has generated .sasm)
        const downloadComplete = false;
        const downloadProgress = 0;

        setStages([
          {
            id: 'device',
            labelKey: 'workflow.device',
            path: '/device',
            complete: deviceComplete && deviceProgress === 100,
            progress: deviceProgress,
          },
          {
            id: 'graph',
            labelKey: 'workflow.graph',
            path: '/graph',
            complete: graphComplete,
            progress: graphProgress,
          },
          {
            id: 'simulation',
            labelKey: 'workflow.sim',
            path: '/simulation',
            complete: simComplete,
            progress: simProgress,
          },
          {
            id: 'download',
            labelKey: 'workflow.download',
            path: '/download',
            complete: downloadComplete,
            progress: downloadProgress,
          },
        ]);
      } catch (error) {
        // API not available, keep default state
      }
    };

    calculateProgress();
  }, [current?.path]);

  const currentStageIndex = STAGES.findIndex((s) => s.path === location.pathname);

  const handleStageClick = (stage: StageStatus, idx: number) => {
    const isAccessible = idx === 0 || stages[idx - 1].complete;

    if (isAccessible) {
      navigate(stage.path);
    } else {
      const prevStage = stages[idx - 1];
      toast.warning(
        t('workflow.stageGate'),
        `${t('workflow.locked')}：${t(prevStage.labelKey as any)}（${t('workflow.progress')}：${prevStage.progress}%）`,
        4000,
      );
    }
  };

  return (
    <div className="h-12 bg-ide-sidebar border-b border-ide-border flex items-center px-4 gap-3">
      <span className="text-xs font-semibold text-ide-textDim uppercase">{t("workflow.progress")}</span>
      <div className="flex items-center gap-2 flex-1">
        {stages.map((stage, idx) => {
          const isActive = idx === currentStageIndex;
          const isPast = idx < currentStageIndex;
          const isAccessible = idx === 0 || stages[idx - 1].complete;

          return (
            <div key={stage.id} className="flex items-center gap-2">
              <button
                onClick={() => handleStageClick(stage, idx)}
                className={`flex items-center gap-2 px-3 py-1.5 rounded text-xs transition-all ${
                  isActive
                    ? 'bg-ide-accent text-white'
                    : isPast
                      ? 'bg-green-600/20 text-green-400 hover:bg-green-600/30'
                      : isAccessible
                        ? 'bg-ide-bg text-ide-text hover:bg-ide-accent/20'
                        : 'bg-ide-bg text-ide-textDim opacity-50 cursor-not-allowed'
                }`}
              >
                <div className="w-5 h-5 rounded-full flex items-center justify-center text-[10px] font-bold">
                  {stage.complete ? (
                    <span>✓</span>
                  ) : stage.progress > 0 ? (
                    <span>{stage.progress}%</span>
                  ) : (
                    <span>{idx + 1}</span>
                  )}
                </div>
                <span className="font-medium">{t(stage.labelKey as any)}</span>
              </button>
              {idx < stages.length - 1 && (
                <div
                  className={`w-8 h-0.5 ${
                    stage.complete ? 'bg-green-500' : 'bg-ide-border'
                  }`}
                />
              )}
            </div>
          );
        })}
      </div>
      <div className="text-xs text-ide-textDim">
        {stages.filter((s) => s.complete).length}/{stages.length} {t("workflow.complete")}
      </div>
    </div>
  );
}
