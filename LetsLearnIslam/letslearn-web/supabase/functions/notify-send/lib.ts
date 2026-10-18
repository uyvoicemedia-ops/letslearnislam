// The logic of the parent-email sender, kept free of the network and of Supabase
// so it can be tested on its own (lib_test.ts). index.ts wires it to the real world.
//
// What this must never do, and the tests check it:
//   * send for real unless NOTIFY_LIVE is exactly "yes";
//   * send to anyone outside NOTIFY_ALLOWLIST while that list is set (first run: your own address);
//   * put a tracking pixel, a remote image or a tracked link in an email;
//   * put an email address, a name or a message body in a log line.

export type Row = {
  id: number;
  to_email: string;
  to_name: string;
  subject: string;
  body: string;
  unsub_token: string;
  event: string;
};

export type Config = {
  live: boolean;
  from: string | null;
  apiKey: string | null;
  appUrl: string;
  allowlist: string[];
  maxPerRun: number;
};

export type Env = (key: string) => string | undefined;

export function configFromEnv(get: Env): Config {
  const n = Number(get("NOTIFY_MAX_PER_RUN"));
  return {
    live: get("NOTIFY_LIVE") === "yes",                                   // anything else, including "true" or "1", is a dry run
    from: get("MAIL_FROM")?.trim() || null,
    apiKey: get("RESEND_API_KEY")?.trim() || null,
    appUrl: (get("APP_URL") ?? "").trim().replace(/\/+$/, ""),
    allowlist: (get("NOTIFY_ALLOWLIST") ?? "").split(",").map((s) => s.trim().toLowerCase()).filter(Boolean),
    maxPerRun: Number.isFinite(n) && n >= 1 ? Math.min(Math.floor(n), 100) : 25,
  };
}

/** Why a LIVE run cannot start, or null. Checked before anything is claimed, so a missing
 *  setting never burns a message's five attempts. */
export function liveProblem(cfg: Config): string | null {
  if (!cfg.live) return null;
  if (!cfg.from) return "MAIL_FROM is not set";
  if (!/^(?:[^<>@\r\n]+<[^<>@\s]+@[^<>@\s]+\.[^<>@\s]+>|[^<>@\s]+@[^<>@\s]+\.[^<>@\s]+)$/.test(cfg.from)) return "MAIL_FROM is not an address";
  if (!cfg.apiKey) return "RESEND_API_KEY is not set";
  if (!/^https:\/\//.test(cfg.appUrl)) return "APP_URL must be the https address the app is served from";
  return null;
}

export function esc(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&#39;");
}

export function unsubscribeUrl(cfg: Config, token: string): string {
  return `${cfg.appUrl}/#unsubscribe=${encodeURIComponent(token)}`;
}

export type Rendered = { subject: string; text: string; html: string; headers: Record<string, string> };

export function renderEmail(row: Row, cfg: Config): Rendered {
  const first = (row.to_name || "").trim().split(/\s+/)[0] || "";
  const greeting = first ? `Assalamu alaikum ${first},` : "Assalamu alaikum,";
  const link = unsubscribeUrl(cfg, row.unsub_token);
  const manage = row.event === "test"
    ? "This was a test email."
    : "To stop emails like this one, open this link. You can also change what you receive in the app under Notifications:";
  const text = `${greeting}\n\n${row.body}\n\n--\n${manage}\n${row.event === "test" ? "" : link + "\n"}`;
  const paras = row.body.split(/\n{2,}/).map((p) => `<p style="margin:0 0 14px">${esc(p).replace(/\n/g, "<br>")}</p>`).join("");
  const html = `<!doctype html><html><body style="font-family:-apple-system,Segoe UI,Arial,sans-serif;font-size:16px;line-height:1.5;color:#212630">`
    + `<p style="margin:0 0 14px">${esc(greeting)}</p>${paras}`
    + `<hr style="border:0;border-top:1px solid #ddd;margin:22px 0 12px">`
    + `<p style="margin:0;font-size:13px;color:#5d6470">${esc(manage)}${row.event === "test" ? "" : ` <a href="${esc(link)}">Stop these emails</a>`}</p>`
    + `</body></html>`;                                                                     // no images, no pixel, no tracked links
  const headers: Record<string, string> = row.event === "test" ? {} : { "List-Unsubscribe": `<${link}>` };
  return { subject: row.subject, text, html, headers };
}

export type Decision =
  | { action: "send" }
  | { action: "dry"; reason: "dry_run" | "not_on_allowlist" }
  | { action: "fail"; reason: "bad_address" };

export function decide(row: Row, cfg: Config): Decision {
  const to = (row.to_email || "").trim().toLowerCase();
  if (!/^[^\s@<>,;]+@[^\s@<>,;]+\.[^\s@<>,;]+$/.test(to)) return { action: "fail", reason: "bad_address" };
  if (!cfg.live) return { action: "dry", reason: "dry_run" };
  if (cfg.allowlist.length > 0 && !cfg.allowlist.includes(to)) return { action: "dry", reason: "not_on_allowlist" };
  return { action: "send" };
}

export function providerRequest(row: Row, cfg: Config): { url: string; init: RequestInit } {
  const r = renderEmail(row, cfg);
  return {
    url: "https://api.resend.com/emails",
    init: {
      method: "POST",
      headers: { "Authorization": `Bearer ${cfg.apiKey}`, "Content-Type": "application/json" },
      body: JSON.stringify({ from: cfg.from, to: [row.to_email.trim()], subject: r.subject, text: r.text, html: r.html, headers: r.headers }),
    },
  };
}

/** 2xx = sent; a rate limit, a timeout or a server fault = try again later; anything else 4xx = it will never work. */
export function classifyStatus(status: number): "sent" | "retry" | "fail" {
  if (status >= 200 && status < 300) return "sent";
  if (status === 408 || status === 425 || status === 429 || status >= 500) return "retry";
  return "fail";
}

export type Deps = {
  claim: (limit: number) => Promise<Row[]>;
  mark: (id: number, result: "sent" | "dry" | "retry" | "failed", error: string | null) => Promise<void>;
  send: (req: { url: string; init: RequestInit }) => Promise<{ status: number }>;
  cfg: Config;
};

export type Summary = { claimed: number; sent: number; dry: number; retry: number; failed: number; live: boolean };

export async function runBatch(d: Deps): Promise<Summary> {
  const s: Summary = { claimed: 0, sent: 0, dry: 0, retry: 0, failed: 0, live: d.cfg.live };
  const rows = await d.claim(d.cfg.maxPerRun);
  s.claimed = rows.length;
  for (const row of rows) {
    const dec = decide(row, d.cfg);
    try {
      if (dec.action === "fail") { await d.mark(row.id, "failed", dec.reason); s.failed++; continue; }
      if (dec.action === "dry") { await d.mark(row.id, "dry", dec.reason); s.dry++; continue; }
      const res = await d.send(providerRequest(row, d.cfg));
      const c = classifyStatus(res.status);
      if (c === "sent") { await d.mark(row.id, "sent", null); s.sent++; }
      else if (c === "retry") { await d.mark(row.id, "retry", `provider answered ${res.status}`); s.retry++; }
      else { await d.mark(row.id, "failed", `provider refused it (${res.status})`); s.failed++; }
    } catch (_e) {
      // a network fault: never include the error text, it can carry the address
      try { await d.mark(row.id, "retry", "could not reach the provider"); s.retry++; } catch { /* the lease will expire and it will be put back */ }
    }
  }
  return s;
}

/** Constant-time comparison, so the secret cannot be guessed a character at a time. */
export function sameSecret(a: string, b: string): boolean {
  const x = new TextEncoder().encode(a), y = new TextEncoder().encode(b);
  let diff = x.length ^ y.length;
  for (let i = 0; i < Math.max(x.length, y.length); i++) diff |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return diff === 0;
}
