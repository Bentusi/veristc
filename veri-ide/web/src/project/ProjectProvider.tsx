import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useState,
  type ReactNode,
} from "react";
import { apiCall, json } from "../lib/api";

export interface ProjectInfo {
  name: string;
  path: string;
  safety_level: string;
  svm_version: string;
  description: string;
  tree: Record<string, string[]>;
}

export interface RecentProject {
  path: string;
  name: string;
  safety_level: string;
  opened_at: string;
  exists: boolean;
  pages: number;
  stations: number;
  blocks: number;
}

export interface RecentBlock {
  id: string;
  name: string;
  version: string;
  category: string;
  scope: string;
  project: string;
  touched_at: string;
}

export interface LauncherState {
  current: ProjectInfo | null;
  recent_projects: RecentProject[];
  recent_blocks: RecentBlock[];
  default_parent_dir: string;
}

export interface CreateProjectInput {
  name: string;
  parent_dir: string;
  safety_level: string;
  svm_version?: string;
}

interface ProjectApi {
  state: LauncherState | null;
  current: ProjectInfo | null;
  error: string | null;
  refresh: () => Promise<void>;
  create: (input: CreateProjectInput) => Promise<ProjectInfo>;
  open: (path: string) => Promise<ProjectInfo>;
  save: () => Promise<void>;
  close: () => Promise<void>;
  forget: (path: string) => Promise<void>;
}

const ProjectContext = createContext<ProjectApi | null>(null);

/**
 * The project the sidecar currently works on, shared by every stage page.
 *
 * Opening a project is a backend operation: it loads stations, pages and blocks
 * from the folder at once. The shell only mirrors that state, so no page ever
 * asks the user for a directory again.
 */
export function ProjectProvider({ children }: { children: ReactNode }) {
  const [state, setState] = useState<LauncherState | null>(null);
  const [error, setError] = useState<string | null>(null);

  const refresh = useCallback(async () => {
    try {
      setState(await apiCall<LauncherState>("/project/state"));
      setError(null);
    } catch (cause) {
      setError((cause as Error).message);
    }
  }, []);

  useEffect(() => {
    refresh();
  }, [refresh]);

  const create = useCallback(
    async (input: CreateProjectInput) => {
      const created = await apiCall<ProjectInfo>(
        "/project/create",
        json({ ...input, parent_dir: input.parent_dir || undefined }),
      );
      await refresh();
      return created;
    },
    [refresh],
  );

  const open = useCallback(
    async (path: string) => {
      const opened = await apiCall<ProjectInfo>("/project/open", json({ path }));
      await refresh();
      return opened;
    },
    [refresh],
  );

  const save = useCallback(async () => {
    await apiCall<ProjectInfo>("/project/save", json({}));
    await refresh();
  }, [refresh]);

  const close = useCallback(async () => {
    await apiCall<{ closed: boolean }>("/project/close", json({}));
    await refresh();
  }, [refresh]);

  const forget = useCallback(
    async (path: string) => {
      await apiCall<{ forgotten: boolean }>("/project/forget", json({ path }));
      await refresh();
    },
    [refresh],
  );

  const value = useMemo<ProjectApi>(
    () => ({
      state,
      current: state?.current ?? null,
      error,
      refresh,
      create,
      open,
      save,
      close,
      forget,
    }),
    [state, error, refresh, create, open, save, close, forget],
  );

  return <ProjectContext.Provider value={value}>{children}</ProjectContext.Provider>;
}

export function useProject(): ProjectApi {
  const context = useContext(ProjectContext);
  if (!context) throw new Error("useProject must be used inside ProjectProvider");
  return context;
}

export function formatWhen(iso: string): string {
  if (!iso) return "";
  const stamp = new Date(iso);
  if (Number.isNaN(stamp.getTime())) return iso;
  return stamp.toLocaleString("zh-CN", {
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
  });
}
