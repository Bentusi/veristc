/** Shared sidecar client: one base URL, one error shape for every stage page. */

export const API_BASE = "http://localhost:8000";

export async function apiCall<T>(path: string, init?: RequestInit): Promise<T> {
  const response = await fetch(`${API_BASE}${path}`, init);
  const text = await response.text();
  if (!response.ok) {
    let detail = text;
    try {
      detail = JSON.parse(text).detail ?? text;
    } catch {
      /* keep the raw body */
    }
    throw new Error(detail || `HTTP ${response.status}`);
  }
  return text ? (JSON.parse(text) as T) : ({} as T);
}

export const json = (body: unknown): RequestInit => ({
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify(body ?? {}),
});

/** The webview runs both inside Tauri (dialog plugin) and in a plain browser. */
export const inTauri = (): boolean =>
  typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;
