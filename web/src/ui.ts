// Tiny DOM helpers; no framework so the page stays small and fast.

type Child = Node | string;

export function h(
  tag: string,
  attrs: Record<string, string> = {},
  ...children: Child[]
): HTMLElement {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (v !== "") el.setAttribute(k, v);
  }
  for (const c of children) {
    if (c !== "") el.append(c);
  }
  return el;
}

export function setStatus(text: string): void {
  const el = document.getElementById("status");
  if (el) el.textContent = text;
}

export function clock(unix: number): string {
  return new Date(unix * 1000).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
}

export function nowSeconds(): number {
  return Math.floor(Date.now() / 1000);
}
