import { api } from "./api";
import { showHome } from "./home";
import { leaveLive, showLive } from "./live";
import { setStatus } from "./ui";

const view = document.getElementById("view") as HTMLElement;

function route(): void {
  const name = location.hash.replace(/^#\//, "") || "home";
  document.querySelectorAll<HTMLAnchorElement>("nav a").forEach((a) => {
    a.toggleAttribute("aria-current", a.dataset.route === name);
  });
  leaveLive();
  if (name === "live") void showLive(view);
  else void showHome(view);
}

async function pollStatus(): Promise<void> {
  try {
    const s = await api.status();
    const parts = [
      s.emby.ok ? `Emby: ${s.emby.server}` : `Emby: ${s.emby.error}`,
      s.live.ok ? `Live: ${s.live.channels?.toLocaleString()} ch` : `Live: ${s.live.error}`,
    ];
    if (s.live.guide) {
      const g = s.live.guide;
      parts.push(
        g.state === "ready"
          ? `Guide: ${g.programmes.toLocaleString()} shows`
          : `Guide: ${g.state}`,
      );
    }
    document.getElementById("status")?.setAttribute("title", parts.join(" · "));
    if (!document.getElementById("status")?.textContent) setStatus(parts.join(" · "));
  } catch {
    setStatus("Server unreachable");
  }
}

window.addEventListener("hashchange", route);
route();
void pollStatus();
window.setInterval(pollStatus, 15_000);
