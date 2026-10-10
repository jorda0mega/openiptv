// Live player. Streams come through openiptv-edge as MPEG-TS and play via
// mpegts.js (Media Source Extensions). Stash buffering is off so playback
// starts on the first decodable frame; the overlay shows how long that took.

import type Mpegts from "mpegts.js";
import { api, type Channel } from "./api";
import { nowNext } from "./live";
import { clock, nowSeconds } from "./ui";

const overlay = () => document.getElementById("player") as HTMLElement;
const video = () => document.getElementById("video") as HTMLVideoElement;
const text = (id: string, value: string) => {
  const el = document.getElementById(id);
  if (el) el.textContent = value;
};

// Loaded on first play so the home screen doesn't pay for it.
let mpegts: typeof Mpegts | null = null;
let player: Mpegts.Player | null = null;
let channels: Channel[] = [];
let index = 0;
let startedAt = 0;
let wired = false;

export async function play(list: Channel[], i: number): Promise<void> {
  channels = list;
  index = i;
  wire();
  overlay().hidden = false;
  text("osd-timing", "Starting…");
  mpegts ??= (await import("mpegts.js")).default;
  start();
}

function start(): void {
  if (!mpegts) return;
  stop();
  const channel = channels[index];
  if (!channel) return;
  text("osd-channel", `${channel.number ?? ""} ${channel.name}`.trim());
  text("osd-timing", "Starting…");
  renderShows(channel.id);
  void refreshShows(channel.id);

  const m = mpegts;
  if (!m.isSupported()) {
    text("osd-timing", "This browser can't play live TS streams");
    return;
  }
  startedAt = performance.now();
  const p = m.createPlayer(
    { type: "mpegts", isLive: true, url: `/live/${channel.id}.ts` },
    {
      enableWorker: true,
      enableStashBuffer: false,
      lazyLoad: false,
      liveBufferLatencyChasing: true,
      autoCleanupSourceBuffer: true,
    },
  );
  p.on(m.Events.ERROR, (type: string, detail: string) => {
    text("osd-timing", `Playback error: ${type} ${detail}`);
  });
  p.attachMediaElement(video());
  p.load();
  void video().play().catch(() => {});
  player = p;

  const v = video();
  const onPlaying = async () => {
    const ms = Math.round(performance.now() - startedAt);
    let detail = "";
    try {
      const status = await api.status();
      if (status.lastZap?.channel === channel.id) {
        detail = ` (provider ${status.lastZap.firstBytesMs} ms)`;
      }
    } catch {
      // Timing detail is optional.
    }
    text("osd-timing", `Started in ${(ms / 1000).toFixed(1)} s${detail}`);
    v.dataset.startMs = String(ms);
  };
  v.addEventListener("playing", onPlaying, { once: true });
}

function stop(): void {
  if (!player) return;
  // Unloading closes the relay, which frees the provider connection.
  player.pause();
  player.unload();
  player.detachMediaElement();
  player.destroy();
  player = null;
}

function close(): void {
  stop();
  overlay().hidden = true;
}

function step(delta: number): void {
  if (!channels.length) return;
  index = (index + delta + channels.length) % channels.length;
  start();
}

function renderShows(id: number): void {
  const info = nowNext.get(id);
  const now = info?.now;
  text("osd-now", now ? `Now: ${now.title} (until ${clock(now.stop)})` : "No guide data for this channel");
  text("osd-next", info?.next ? `Next: ${clock(info.next.start)} ${info.next.title}` : "");
}

async function refreshShows(id: number): Promise<void> {
  const info = nowNext.get(id);
  if (info && (info.refresh_at == null || info.refresh_at > nowSeconds())) return;
  try {
    const fresh = await api.nowNext([id]);
    for (const [k, v] of Object.entries(fresh)) nowNext.set(Number(k), v);
    if (channels[index]?.id === id) renderShows(id);
  } catch {
    // Overlay keeps whatever it had.
  }
}

function wire(): void {
  if (wired) return;
  wired = true;
  document.getElementById("player-close")?.addEventListener("click", close);
  document.getElementById("player-prev")?.addEventListener("click", () => step(-1));
  document.getElementById("player-next")?.addEventListener("click", () => step(1));
  document.addEventListener("keydown", (e) => {
    if (overlay().hidden) return;
    if (e.key === "Escape") close();
    if (e.key === "ArrowUp") step(-1);
    if (e.key === "ArrowDown") step(1);
  });
  // Keep the overlay's titles right across programme boundaries.
  window.setInterval(() => {
    const channel = channels[index];
    if (!overlay().hidden && channel) void refreshShows(channel.id);
  }, 15_000);
}
