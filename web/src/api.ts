// Typed calls to openiptv-edge, plus a cache-first helper: render the last
// known answer immediately, then replace it when the network answers.

export interface CardImage {
  url: string;
  contain: boolean;
}

export interface Card {
  id: string;
  kind: string;
  title: string;
  subtitle: string | null;
  images: CardImage[];
  progress: number | null;
}

export interface Row {
  title: string;
  shape: "portrait" | "square" | "fourThree" | "landscape";
  aspect: number;
  cards: Card[];
}

export interface Category {
  id: string;
  name: string;
  channels: number;
}

export interface Channel {
  id: number;
  number: number | null;
  name: string;
  logo: string | null;
  category: string | null;
}

export interface Show {
  title: string;
  start: number;
  stop: number;
}

export interface NowNext {
  now: Show | null;
  next: Show | null;
  refresh_at: number | null;
  source: "guide" | "panel" | "none";
}

export interface Status {
  emby: { ok: boolean; server?: string; error?: string };
  live: {
    ok: boolean;
    channels?: number;
    error?: string;
    guide?: { state: string; programmes: number; seconds: number };
  };
  lastZap: { channel: number; headersMs: number; firstBytesMs: number } | null;
}

async function get<T>(path: string): Promise<T> {
  const res = await fetch(path);
  if (!res.ok) {
    const body = await res.json().catch(() => ({}));
    throw new Error(body.error ?? `HTTP ${res.status}`);
  }
  return res.json() as Promise<T>;
}

export const api = {
  status: () => get<Status>("/api/status"),
  home: (width: number) => get<Row[]>(`/api/home?width=${width}`),
  categories: () => get<Category[]>("/api/live/categories"),
  channels: (category?: string, q?: string) => {
    const params = new URLSearchParams();
    if (category) params.set("category", category);
    if (q) params.set("q", q);
    return get<Channel[]>(`/api/live/channels?${params}`);
  },
  nowNext: (ids: number[]) =>
    get<Record<string, NowNext>>(`/api/live/nownext?ids=${ids.join(",")}`),
};

/** Calls `render` with the cached value (if any) right away, then again with
 *  fresh data if it differs. Returns the fresh value. */
export async function cacheFirst<T>(
  key: string,
  load: () => Promise<T>,
  render: (value: T, fresh: boolean) => void,
): Promise<T> {
  const cached = localStorage.getItem(key);
  if (cached) {
    try {
      render(JSON.parse(cached) as T, false);
    } catch {
      localStorage.removeItem(key);
    }
  }
  const value = await load();
  const json = JSON.stringify(value);
  if (json !== cached) {
    try {
      localStorage.setItem(key, json);
    } catch {
      // Quota exceeded: still render, just don't persist.
    }
    render(value, true);
  }
  return value;
}
