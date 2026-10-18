import { assert, assertEquals, assertFalse, assertMatch } from "jsr:@std/assert@1";
import {
  classifyStatus, configFromEnv, decide, esc, liveProblem, providerRequest, renderEmail, runBatch, sameSecret,
  type Config, type Row,
} from "./lib.ts";

const base: Config = { live: true, from: "Karimia <notifications@mail.example.org>", apiKey: "re_test_key_123", appUrl: "https://app.example.org", allowlist: [], maxPerRun: 25 };
const row = (o: Partial<Row> = {}): Row => ({ id: 1, to_email: "fatima@example.com", to_name: "Fatima Khan", subject: "Aisha was marked absent", body: "Aisha was marked absent from Qaida 1 on Tuesday 14 October.\n\nIf this is a mistake, please tell the madrasah.", unsub_token: "a".repeat(64), event: "absence", ...o });
const env = (m: Record<string, string>) => (k: string) => m[k];

Deno.test("only the exact word yes goes live", () => {
  for (const v of ["true", "1", "YES", "Yes", "y", "on", "", " yes"]) assertFalse(configFromEnv(env({ NOTIFY_LIVE: v })).live, `"${v}" must stay a dry run`);
  assert(configFromEnv(env({ NOTIFY_LIVE: "yes" })).live);
  assertFalse(configFromEnv(env({})).live, "unset is a dry run");
});
Deno.test("the allowlist is lower-cased and trimmed; the batch size is bounded", () => {
  assertEquals(configFromEnv(env({ NOTIFY_ALLOWLIST: " Me@Example.com , you@x.org ,," })).allowlist, ["me@example.com", "you@x.org"]);
  assertEquals(configFromEnv(env({})).maxPerRun, 25);
  assertEquals(configFromEnv(env({ NOTIFY_MAX_PER_RUN: "7" })).maxPerRun, 7);
  assertEquals(configFromEnv(env({ NOTIFY_MAX_PER_RUN: "100000" })).maxPerRun, 100);
  assertEquals(configFromEnv(env({ NOTIFY_MAX_PER_RUN: "-3" })).maxPerRun, 25);
  assertEquals(configFromEnv(env({ NOTIFY_MAX_PER_RUN: "abc" })).maxPerRun, 25);
  assertEquals(configFromEnv(env({ APP_URL: "https://a.org///" })).appUrl, "https://a.org");
});
Deno.test("a live run refuses to start with a setting missing; a dry run never complains", () => {
  assertEquals(liveProblem({ ...base, live: false, from: null, apiKey: null, appUrl: "" }), null);
  assertEquals(liveProblem(base), null);
  assertMatch(liveProblem({ ...base, from: null })!, /MAIL_FROM/);
  assertMatch(liveProblem({ ...base, from: "not an address" })!, /MAIL_FROM/);
  assertMatch(liveProblem({ ...base, apiKey: null })!, /RESEND_API_KEY/);
  assertMatch(liveProblem({ ...base, appUrl: "http://app.example.org" })!, /https/);
  assertMatch(liveProblem({ ...base, appUrl: "" })!, /https/);
  assertEquals(liveProblem({ ...base, from: "notifications@mail.example.org" }), null);
  assertMatch(liveProblem({ ...base, from: "a@b.co\nBcc: x@y.zz" })!, /MAIL_FROM/);
  assertMatch(liveProblem({ ...base, from: "Name <a@b.co> <c@d.ee>" })!, /MAIL_FROM/);
});
Deno.test("escaping", () => assertEquals(esc(`<a href="x">'&'</a>`), "&lt;a href=&quot;x&quot;&gt;&#39;&amp;&#39;&lt;/a&gt;"));

Deno.test("an email greets by first name, holds the body, and links only to unsubscribe", () => {
  const r = renderEmail(row(), base);
  assert(r.text.startsWith("Assalamu alaikum Fatima,"));
  assert(r.text.includes("Aisha was marked absent from Qaida 1"));
  assertFalse(r.text.includes("Khan"), "the parent's surname is not needed");
  assertEquals((r.html.match(/href=/g) ?? []).length, 1, "exactly one link");
  assert(r.html.includes(`href="https://app.example.org/#unsubscribe=${"a".repeat(64)}"`));
  assertEquals(r.headers["List-Unsubscribe"], `<https://app.example.org/#unsubscribe=${"a".repeat(64)}>`);
});
Deno.test("no pixel, no remote image, no script, no tracked link", () => {
  const h = renderEmail(row({ body: "hello" }), base).html;
  for (const bad of ["<img", "src=", "<script", "<iframe", "<link", "background:url", "@import"]) assertFalse(h.toLowerCase().includes(bad), bad);
});
Deno.test("a message body cannot inject markup", () => {
  const r = renderEmail(row({ body: `<script>alert(1)</script> & <img src=x onerror=y>\n\nsecond "para"` }), base);
  assertFalse(r.html.includes("<script>")); assertFalse(r.html.includes("<img"));
  assert(r.html.includes("&lt;script&gt;")); assert(r.html.includes("&quot;para&quot;"));
  assertEquals((r.html.match(/<p /g) ?? []).length, 4, "greeting, two paragraphs, and the footer");
});
Deno.test("a name cannot inject markup either", () => {
  const r = renderEmail(row({ to_name: `<b>Evil</b> Person` }), base);
  assertFalse(r.html.includes("<b>")); assert(r.html.includes("&lt;b&gt;Evil&lt;/b&gt;"));
});
Deno.test("a test email has no unsubscribe link and no header, and says it is a test", () => {
  const r = renderEmail(row({ event: "test", subject: "Test email from LetsLearn", body: "This is a test." }), base);
  assertFalse(r.html.includes("href=")); assertEquals(r.headers, {}); assert(r.text.includes("This was a test email."));
});

Deno.test("a dry run never sends", () => assertEquals(decide(row(), { ...base, live: false }), { action: "dry", reason: "dry_run" }));
Deno.test("live and no allowlist sends", () => assertEquals(decide(row(), base), { action: "send" }));
Deno.test("while an allowlist is set, nobody else is really emailed", () => {
  const c = { ...base, allowlist: ["me@example.com"] };
  assertEquals(decide(row({ to_email: "fatima@example.com" }), c), { action: "dry", reason: "not_on_allowlist" });
  assertEquals(decide(row({ to_email: "Me@Example.COM" }), c), { action: "send" });
  assertEquals(decide(row({ to_email: "me@example.com.evil.org" }), c), { action: "dry", reason: "not_on_allowlist" });
});
Deno.test("a bad or sneaky address is refused, never sent", () => {
  for (const a of ["", "nope", "a@b", "a@b.co,c@d.co", "a@b.co;c@d.co", "<a@b.co>", "a@b.co\nBcc: x@y.zz", "a b@c.de", "@b.co"]) {
    assertEquals(decide(row({ to_email: a }), base), { action: "fail", reason: "bad_address" }, JSON.stringify(a));
  }
});
Deno.test("the provider request has exactly one recipient and the right sender", () => {
  const { url, init } = providerRequest(row(), base);
  assertEquals(url, "https://api.resend.com/emails");
  const b = JSON.parse(init.body as string);
  assertEquals(b.to, ["fatima@example.com"]); assertEquals(b.from, base.from); assertEquals(b.subject, "Aisha was marked absent");
  assertFalse("cc" in b || "bcc" in b || "reply_to" in b);
  assertEquals((init.headers as Record<string, string>)["Authorization"], "Bearer re_test_key_123");
});
Deno.test("status classes", () => {
  for (const s of [200, 201, 202]) assertEquals(classifyStatus(s), "sent");
  for (const s of [408, 425, 429, 500, 502, 503, 504]) assertEquals(classifyStatus(s), "retry");
  for (const s of [400, 401, 403, 404, 422]) assertEquals(classifyStatus(s), "fail");
  assertEquals(classifyStatus(301), "fail");
});
Deno.test("constant-time secret compare", () => {
  assert(sameSecret("abc", "abc")); assertFalse(sameSecret("abc", "abd")); assertFalse(sameSecret("abc", "abcd")); assertFalse(sameSecret("", "x"));
});

function harness(rows: Row[], cfg: Config, answer: (r: Row) => number | Error) {
  const marks: { id: number; result: string; error: string | null }[] = []; const sent: string[] = []; let asked = -1;
  return {
    marks, sent, get asked() { return asked; },
    deps: {
      cfg,
      claim: (n: number) => { asked = n; return Promise.resolve(rows); },
      mark: (id: number, result: "sent" | "dry" | "retry" | "failed", error: string | null) => { marks.push({ id, result, error }); return Promise.resolve(); },
      send: (req: { url: string; init: RequestInit }) => {
        const to = JSON.parse(req.init.body as string).to[0]; sent.push(to);
        const r = answer(rows.find((x) => x.to_email === to)!);
        return r instanceof Error ? Promise.reject(r) : Promise.resolve({ status: r });
      },
    },
  };
}

Deno.test("a dry run marks everything dry and calls the provider zero times", async () => {
  const h = harness([row({ id: 1 }), row({ id: 2, to_email: "b@example.com" })], { ...base, live: false }, () => 200);
  const s = await runBatch(h.deps);
  assertEquals(h.sent.length, 0); assertEquals(s, { claimed: 2, sent: 0, dry: 2, retry: 0, failed: 0, live: false });
  assertEquals(h.marks.map((m) => m.result), ["dry", "dry"]);
});
Deno.test("a live run sends and marks each by what the provider said", async () => {
  const rows = [row({ id: 1, to_email: "ok@example.com" }), row({ id: 2, to_email: "slow@example.com" }), row({ id: 3, to_email: "bad@example.com" })];
  const h = harness(rows, base, (r) => r.to_email.startsWith("ok") ? 200 : r.to_email.startsWith("slow") ? 429 : 422);
  const s = await runBatch(h.deps);
  assertEquals(h.marks.map((m) => m.result), ["sent", "retry", "failed"]); assertEquals(s.sent, 1); assertEquals(s.retry, 1); assertEquals(s.failed, 1);
});
Deno.test("an allowlist keeps real mail to the allowed addresses even in a live run", async () => {
  const h = harness([row({ id: 1, to_email: "me@example.com" }), row({ id: 2, to_email: "parent@example.com" })], { ...base, allowlist: ["me@example.com"] }, () => 200);
  const s = await runBatch(h.deps);
  assertEquals(h.sent, ["me@example.com"]); assertEquals(s.sent, 1); assertEquals(s.dry, 1);
  assertEquals(h.marks.find((m) => m.id === 2)!.error, "not_on_allowlist");
});
Deno.test("a network fault retries, and the stored reason never contains the address", async () => {
  const h = harness([row({ id: 1, to_email: "secret.person@example.com" })], base, () => new Error("connect failed for secret.person@example.com"));
  const s = await runBatch(h.deps);
  assertEquals(s.retry, 1); assertEquals(h.marks[0].result, "retry"); assertEquals(h.marks[0].error, "could not reach the provider");
  assertFalse(JSON.stringify(h.marks).includes("secret.person"));
});
Deno.test("one failure does not stop the rest, and a bad address is failed without a call", async () => {
  const h = harness([row({ id: 1, to_email: "nope" }), row({ id: 2, to_email: "good@example.com" })], base, () => 200);
  const s = await runBatch(h.deps);
  assertEquals(h.sent, ["good@example.com"]); assertEquals(s.failed, 1); assertEquals(s.sent, 1);
  assertEquals(h.marks[0], { id: 1, result: "failed", error: "bad_address" });
});
Deno.test("the batch size comes from the config", async () => {
  const h = harness([], { ...base, maxPerRun: 7 }, () => 200); await runBatch(h.deps); assertEquals(h.asked, 7);
});
Deno.test("if marking fails after a send fault, the run still finishes", async () => {
  const d = harness([row()], base, () => new Error("x")).deps;
  const s = await runBatch({ ...d, mark: () => Promise.reject(new Error("db down")) });
  assertEquals(s.claimed, 1);
});
