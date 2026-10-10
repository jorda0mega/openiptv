// Home: Continue Watching, Next Up and Latest per library. Card boxes have
// their final size before any image loads, and each card tries its image
// candidates in order so a broken image never leaves a blank cover.

import { api, cacheFirst, type Card, type Row } from "./api";
import { h, setStatus } from "./ui";

const WIDE = { portrait: 150, square: 170, fourThree: 220, landscape: 280 } as const;
const NARROW = { portrait: 112, square: 128, fourThree: 168, landscape: 220 } as const;
const CARD_WIDTH = matchMedia("(max-width: 720px)").matches ? NARROW : WIDE;

export async function showHome(view: HTMLElement): Promise<void> {
  const container = h("div", { class: "home" });
  view.replaceChildren(container);
  const width = Math.round(CARD_WIDTH.portrait * devicePixelRatio);
  const started = performance.now();
  try {
    await cacheFirst(
      "home",
      () => api.home(width),
      (rows, fresh) => {
        container.replaceChildren(...rows.map(renderRow));
        if (fresh) setStatus(`Home loaded in ${Math.round(performance.now() - started)} ms`);
      },
    );
  } catch (e) {
    if (!container.childElementCount) {
      container.append(h("p", { class: "empty" }, "Emby isn't connected. ", h("a", { href: "#/accounts" }, "Sign in")));
    }
    setStatus(`Emby: ${(e as Error).message}`);
  }
}

function renderRow(row: Row): HTMLElement {
  const width = CARD_WIDTH[row.shape];
  return h(
    "section",
    { class: "row", "aria-label": row.title },
    h("h2", {}, row.title),
    h(
      "div",
      { class: "row-cards", role: "list" },
      ...row.cards.map((c) => renderCard(c, width, row.aspect)),
    ),
  );
}

function renderCard(card: Card, width: number, aspect: number): HTMLElement {
  const frame = h("div", {
    class: "card-art",
    style: `width:${width}px;aspect-ratio:${aspect}`,
  });
  loadFirst(frame, card);
  if (card.progress != null) {
    frame.append(
      h("div", { class: "progress" }, h("div", { style: `width:${card.progress}%` })),
    );
  }
  return h(
    "article",
    { class: "card", role: "listitem", style: `width:${width}px`, title: card.title },
    frame,
    h("div", { class: "card-title" }, card.title),
    card.subtitle ? h("div", { class: "card-subtitle" }, card.subtitle) : "",
  );
}

/** Try each image candidate until one loads; placeholder if none do. */
function loadFirst(frame: HTMLElement, card: Card, index = 0): void {
  const candidate = card.images[index];
  if (!candidate) {
    frame.classList.add("placeholder");
    frame.prepend(h("span", { class: "placeholder-text" }, card.title));
    return;
  }
  const img = h("img", {
    alt: "",
    loading: "lazy",
    decoding: "async",
    src: candidate.url,
    class: candidate.contain ? "contain" : "",
  }) as HTMLImageElement;
  img.addEventListener("error", () => {
    img.remove();
    loadFirst(frame, card, index + 1);
  }, { once: true });
  frame.prepend(img);
}
