// Live TV: categories on the left, a virtualised channel list on the right.
// Only visible rows exist in the DOM (providers have 10k+ channels), and
// now/next is fetched for visible rows only, then refreshed exactly when a
// programme ends instead of on a polling interval.

import { api, cacheFirst, type Category, type Channel, type NowNext } from "./api";
import { play } from "./player";
import { clock, h, nowSeconds, setStatus } from "./ui";

const ROW_HEIGHT = 64;
const OVERSCAN = 6;

/** Shared with the player so its overlay shows the same titles. */
export const nowNext = new Map<number, NowNext>();
const channelCache = new Map<string, Channel[]>();

let list: Channel[] = [];
let scroller: HTMLElement;
let rowsEl: HTMLElement;
let spacer: HTMLElement;
let pending: number | undefined;
let boundaryTimer: number | undefined;
let progressTimer: number | undefined;

export async function showLive(view: HTMLElement): Promise<void> {
  const categoryList = h("div", { class: "category-list", role: "listbox", "aria-label": "Categories" });
  const categoryFilter = h("input", {
    type: "search",
    placeholder: "Filter categories",
    "aria-label": "Filter categories",
  }) as HTMLInputElement;
  const search = h("input", {
    type: "search",
    placeholder: "Search all channels",
    "aria-label": "Search all channels",
  }) as HTMLInputElement;
  rowsEl = h("div", { class: "channel-rows" });
  spacer = h("div", { class: "channel-spacer" }, rowsEl);
  scroller = h("div", { class: "channel-scroller", role: "list", "aria-label": "Channels" }, spacer);
  view.replaceChildren(
    h(
      "div",
      { class: "live" },
      h("aside", { class: "categories" }, categoryFilter, categoryList),
      h("section", { class: "channels" }, search, scroller),
    ),
  );
  scroller.addEventListener("scroll", () => requestAnimationFrame(renderVisible), { passive: true });
  window.clearInterval(progressTimer);
  progressTimer = window.setInterval(renderVisible, 30_000);

  let categories: Category[] = [];
  const renderCategories = () => {
    const f = categoryFilter.value.toLowerCase();
    const selected = localStorage.getItem("category");
    categoryList.replaceChildren(
      ...categories
        .filter((c) => c.name.toLowerCase().includes(f))
        .map((c) => {
          const b = h(
            "button",
            {
              class: "category" + (c.id === selected ? " selected" : ""),
              role: "option",
              "aria-selected": String(c.id === selected),
            },
            h("span", {}, c.name),
            h("span", { class: "count" }, String(c.channels)),
          );
          b.addEventListener("click", () => {
            localStorage.setItem("category", c.id);
            search.value = "";
            renderCategories();
            void loadChannels(c.id);
          });
          return b;
        }),
    );
  };
  categoryFilter.addEventListener("input", renderCategories);

  let searchTimer: number | undefined;
  search.addEventListener("input", () => {
    window.clearTimeout(searchTimer);
    searchTimer = window.setTimeout(() => {
      const q = search.value.trim();
      if (q.length >= 2) void loadChannels(undefined, q);
    }, 200);
  });

  try {
    await cacheFirst("categories", api.categories, (value) => {
      categories = value;
      if (!localStorage.getItem("category") && value[0]) {
        localStorage.setItem("category", value[0].id);
      }
      renderCategories();
    });
  } catch (e) {
    setStatus(`Live TV: ${(e as Error).message}`);
    return;
  }
  const selected = localStorage.getItem("category");
  if (selected) await loadChannels(selected);
}

async function loadChannels(category?: string, q?: string): Promise<void> {
  const key = q ? `q:${q}` : `c:${category}`;
  const cached = channelCache.get(key);
  if (cached) {
    setList(cached);
  }
  const started = performance.now();
  try {
    const fresh = await api.channels(category, q);
    channelCache.set(key, fresh);
    setList(fresh);
    setStatus(`${fresh.length} channels in ${Math.round(performance.now() - started)} ms`);
  } catch (e) {
    setStatus(`Channels: ${(e as Error).message}`);
  }
}

function setList(channels: Channel[]): void {
  list = channels;
  spacer.style.height = `${channels.length * ROW_HEIGHT}px`;
  scroller.scrollTop = 0;
  renderVisible();
}

function renderVisible(): void {
  if (!scroller?.isConnected) return;
  const first = Math.max(0, Math.floor(scroller.scrollTop / ROW_HEIGHT) - OVERSCAN);
  const last = Math.min(
    list.length,
    Math.ceil((scroller.scrollTop + scroller.clientHeight) / ROW_HEIGHT) + OVERSCAN,
  );
  rowsEl.style.transform = `translateY(${first * ROW_HEIGHT}px)`;
  const visible = list.slice(first, last);
  rowsEl.replaceChildren(...visible.map((c, i) => renderChannel(c, first + i)));
  requestNowNext(visible.map((c) => c.id));
}

function renderChannel(channel: Channel, index: number): HTMLElement {
  const info = nowNext.get(channel.id);
  const now = nowSeconds();
  const logo = channel.logo
    ? (h("img", { src: channel.logo, alt: "", loading: "lazy", decoding: "async" }) as HTMLImageElement)
    : h("span", { class: "logo-fallback" }, channel.name.slice(0, 2));
  if (logo instanceof HTMLImageElement) {
    logo.addEventListener("error", () => logo.replaceWith(h("span", { class: "logo-fallback" }, channel.name.slice(0, 2))), { once: true });
  }
  const show = info?.now;
  const progress = show ? Math.min(100, Math.max(0, ((now - show.start) / (show.stop - show.start)) * 100)) : 0;
  const row = h(
    "button",
    {
      class: "channel",
      role: "listitem",
      "data-id": String(channel.id),
      "data-source": info?.source ?? "loading",
      title: info ? `Guide source: ${info.source}` : "Loading guide…",
    },
    h("span", { class: "channel-number" }, channel.number != null ? String(channel.number) : ""),
    h("span", { class: "channel-logo" }, logo),
    h(
      "span",
      { class: "channel-text" },
      h("span", { class: "channel-name" }, channel.name),
      h(
        "span",
        { class: "channel-now" },
        show ? show.title : info ? "No guide data" : "…",
        show ? h("span", { class: "muted" }, ` · until ${clock(show.stop)}`) : "",
      ),
      show ? h("span", { class: "show-progress" }, h("span", { style: `width:${progress}%` })) : "",
    ),
    h(
      "span",
      { class: "channel-next muted" },
      info?.next ? `${clock(info.next.start)} ${info.next.title}` : "",
    ),
  );
  row.addEventListener("click", () => void play(list, index));
  return row;
}

/** Fetch now/next for visible channels that have none or whose answer expired. */
function requestNowNext(ids: number[]): void {
  window.clearTimeout(pending);
  pending = window.setTimeout(async () => {
    const now = nowSeconds();
    const stale = ids.filter((id) => {
      const info = nowNext.get(id);
      return !info || (info.refresh_at != null && info.refresh_at <= now);
    });
    for (let i = 0; i < stale.length; i += 50) {
      try {
        const batch = await api.nowNext(stale.slice(i, i + 50));
        for (const [id, info] of Object.entries(batch)) nowNext.set(Number(id), info);
      } catch {
        // Keep showing what we have; the boundary timer retries.
      }
    }
    if (stale.length) renderVisible();
    scheduleBoundary(ids);
  }, 120);
}

/** One timer for the earliest programme change among visible channels. */
function scheduleBoundary(ids: number[]): void {
  window.clearTimeout(boundaryTimer);
  const next = Math.min(
    ...ids.map((id) => nowNext.get(id)?.refresh_at ?? Infinity),
  );
  if (!Number.isFinite(next)) return;
  const delay = Math.max(1000, (next - nowSeconds()) * 1000 + 1500);
  boundaryTimer = window.setTimeout(renderVisible, Math.min(delay, 2 ** 31 - 1));
}

export function leaveLive(): void {
  window.clearInterval(progressTimer);
  window.clearTimeout(boundaryTimer);
}
