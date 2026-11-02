type EventHandler<T = unknown> = (data: T) => void;

interface EventMap {
  'bindings:changed': Array<{ var_name: string; channel: number }>;
  'project:updated': { name: string; path: string };
  'station:saved': { station_id: string };
  'module:added': { moduleId: string; kind: string };
  'module:removed': { moduleId: string };
  'page:saved': { pageId: string };
  'compile:result': { errors: number; warnings: number };
  'menu:openPanel': 'new-project' | 'open-project' | 'new-block';
}

class EventBus {
  private handlers = new Map<keyof EventMap, Set<EventHandler<any>>>();

  on<K extends keyof EventMap>(event: K, handler: EventHandler<EventMap[K]>): () => void {
    if (!this.handlers.has(event)) {
      this.handlers.set(event, new Set());
    }
    this.handlers.get(event)!.add(handler);
    return () => this.off(event, handler);
  }

  off<K extends keyof EventMap>(event: K, handler: EventHandler<EventMap[K]>): void {
    this.handlers.get(event)?.delete(handler);
  }

  emit<K extends keyof EventMap>(event: K, data: EventMap[K]): void {
    this.handlers.get(event)?.forEach((handler) => {
      try {
        handler(data);
      } catch (error) {
        console.error(`EventBus handler error for ${event}:`, error);
      }
    });
  }

  clear(): void {
    this.handlers.clear();
  }
}

export const eventBus = new EventBus();
export type { EventMap };
