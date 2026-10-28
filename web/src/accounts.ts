// Accounts: sign in to Emby and an Xtream Codes subscription. Logins go to
// this Zapline server, which keeps them only in memory (never on disk) and
// talks to your providers directly. Nothing is stored in the browser.

import { api } from "./api";
import { h, setStatus } from "./ui";

export async function showAccounts(view: HTMLElement): Promise<void> {
  const container = h("div", { class: "accounts" });
  view.replaceChildren(container);
  await render(container);
}

async function render(container: HTMLElement): Promise<void> {
  let status;
  try {
    status = await api.status();
  } catch (e) {
    container.replaceChildren(h("p", { class: "empty" }, `Server unreachable: ${(e as Error).message}`));
    return;
  }
  const refresh = () => void render(container);
  container.replaceChildren(
    h("h1", {}, "Accounts"),
    h("p", { class: "muted" },
      "Your logins are sent only to this Zapline server, which keeps them in memory (not on disk) and never logs them. Restarting the server signs you out."),
    status.emby.ok ? signedIn("Emby", status.emby.server ?? "", "emby", refresh) : embyForm(refresh),
    status.live.ok
      ? signedIn("Live TV", `${(status.live.channels ?? 0).toLocaleString()} channels`, "live", refresh)
      : xtreamForm(refresh),
  );
}

function signedIn(title: string, detail: string, what: "emby" | "live", refresh: () => void): HTMLElement {
  const out = h("button", { class: "secondary" }, "Sign out");
  out.addEventListener("click", async () => {
    await api.signout(what);
    refresh();
  });
  return h("section", { class: "account-card" }, h("h2", {}, title), h("p", {}, `Connected · ${detail}`), out);
}

function field(label: string, attrs: Record<string, string>): [HTMLElement, HTMLInputElement] {
  const input = h("input", attrs) as HTMLInputElement;
  return [h("label", {}, h("span", {}, label), input), input];
}

function embyForm(refresh: () => void): HTMLElement {
  const mode = h("select", { "aria-label": "Sign in with" }) as HTMLSelectElement;
  mode.append(new Option("Server login", "server"), new Option("Emby Connect", "connect"));
  const [urlRow, url] = field("Server address", { type: "url", placeholder: "emby.example.com or 192.168.1.10:8096", autocomplete: "url" });
  const [userRow, user] = field("Username", { autocomplete: "username" });
  const [passRow, pass] = field("Password", { type: "password", autocomplete: "current-password" });
  const error = h("p", { class: "error", role: "alert" });
  const submit = h("button", { type: "submit" }, "Sign in");
  mode.addEventListener("change", () => {
    urlRow.hidden = mode.value === "connect";
    (userRow.firstChild as HTMLElement).textContent = mode.value === "connect" ? "Email or username" : "Username";
  });
  const form = h("form", { class: "account-card" },
    h("h2", {}, "Emby"), mode, urlRow, userRow, passRow, error, submit) as HTMLFormElement;
  form.addEventListener("submit", async (e) => {
    e.preventDefault();
    submit.setAttribute("disabled", "");
    error.textContent = "";
    try {
      await api.signinEmby({ mode: mode.value, url: url.value, username: user.value, password: pass.value });
      pass.value = "";
      localStorage.removeItem("home");
      setStatus("Signed in to Emby");
      refresh();
    } catch (err) {
      error.textContent = (err as Error).message;
    } finally {
      submit.removeAttribute("disabled");
    }
  });
  return form;
}

function xtreamForm(refresh: () => void): HTMLElement {
  const [urlRow, url] = field("Server", { type: "url", placeholder: "http://line.example.com:8080", autocomplete: "url" });
  const [userRow, user] = field("Username", { autocomplete: "username" });
  const [passRow, pass] = field("Password", { type: "password", autocomplete: "current-password" });
  // A pasted get.php / player_api.php link carries the username and password.
  url.addEventListener("input", () => {
    try {
      const link = new URL(url.value);
      const u = link.searchParams.get("username");
      const p = link.searchParams.get("password");
      if (u && p) {
        user.value = u;
        pass.value = p;
        url.value = `${link.protocol}//${link.host}`;
      }
    } catch {
      // Not a full URL yet.
    }
  });
  const error = h("p", { class: "error", role: "alert" });
  const submit = h("button", { type: "submit" }, "Sign in");
  const form = h("form", { class: "account-card" },
    h("h2", {}, "Live TV · Xtream Codes"), urlRow, userRow, passRow, error, submit) as HTMLFormElement;
  form.addEventListener("submit", async (e) => {
    e.preventDefault();
    submit.setAttribute("disabled", "");
    error.textContent = "Checking…";
    try {
      const result = await api.signinXtream({ url: url.value, username: user.value, password: pass.value });
      pass.value = "";
      localStorage.removeItem("categories");
      setStatus(`Live TV: ${result.channels.toLocaleString()} channels`);
      refresh();
    } catch (err) {
      error.textContent = (err as Error).message;
    } finally {
      submit.removeAttribute("disabled");
    }
  });
  return form;
}
