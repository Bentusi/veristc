import { useI18n } from "../../lib/i18n";

interface ErrorBannerProps {
  error: Error | string | null;
  onRetry?: () => void;
  onDismiss?: () => void;
  className?: string;
}

export function ErrorBanner({ error, onRetry, onDismiss, className = '' }: ErrorBannerProps) {
  const { t } = useI18n();
  if (!error) return null;

  const message = error instanceof Error ? error.message : error;

  return (
    <div
      className={`px-4 py-3 rounded-lg border border-red-500/40 bg-red-500/10 text-sm text-red-300 flex items-start gap-3 ${className}`}
    >
      <span className="text-lg">⚠</span>
      <div className="flex-1">
        <div className="font-semibold">{t("errorBanner.error")}</div>
        <div className="mt-1 text-xs">{message}</div>
        {onRetry && (
          <button
            onClick={onRetry}
            className="mt-2 px-3 py-1 bg-red-600/20 hover:bg-red-600/30 border border-red-500/50 rounded text-xs transition-colors"
          >
            {t("errorBanner.retry")}
          </button>
        )}
      </div>
      {onDismiss && (
        <button
          onClick={onDismiss}
          className="text-red-300/70 hover:text-red-300 text-lg leading-none"
        >
          ×
        </button>
      )}
    </div>
  );
}

interface WarningBannerProps {
  message: string;
  onDismiss?: () => void;
  className?: string;
}

export function WarningBanner({ message, onDismiss, className = '' }: WarningBannerProps) {
  return (
    <div
      className={`px-4 py-3 rounded-lg border border-yellow-500/40 bg-yellow-500/10 text-sm text-yellow-300 flex items-start gap-3 ${className}`}
    >
      <span className="text-lg">⚠</span>
      <div className="flex-1">{message}</div>
      {onDismiss && (
        <button
          onClick={onDismiss}
          className="text-yellow-300/70 hover:text-yellow-300 text-lg leading-none"
        >
          ×
        </button>
      )}
    </div>
  );
}

interface InfoBannerProps {
  message: string;
  onDismiss?: () => void;
  className?: string;
}

export function InfoBanner({ message, onDismiss, className = '' }: InfoBannerProps) {
  return (
    <div
      className={`px-4 py-3 rounded-lg border border-blue-500/40 bg-blue-500/10 text-sm text-blue-300 flex items-start gap-3 ${className}`}
    >
      <span className="text-lg">ℹ</span>
      <div className="flex-1">{message}</div>
      {onDismiss && (
        <button
          onClick={onDismiss}
          className="text-blue-300/70 hover:text-blue-300 text-lg leading-none"
        >
          ×
        </button>
      )}
    </div>
  );
}
