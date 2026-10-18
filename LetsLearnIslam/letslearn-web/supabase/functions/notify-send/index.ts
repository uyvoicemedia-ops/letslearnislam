// notify-send: sends the parent emails that the database has queued.
//
// Run it on a schedule (see docs/notifications.md). It does NOTHING real until you set
// NOTIFY_LIVE=yes: until then every message is marked "dry" and no mail leaves.
//
// Secrets come from the function's environment (supabase secrets set ...), never from this repo:
//   NOTIFY_SECRET          a long random string; the scheduler sends it in the x-notify-secret header
//   NOTIFY_LIVE            "yes" to send for real; anything else is a dry run
//   NOTIFY_ALLOWLIST       comma-separated addresses; while set, only those are really sent to
//   MAIL_FROM              e.g.  Karimia <notifications@mail.yourdomain.org>   (a domain YOU verified)
//   RESEND_API_KEY         the provider's key
//   APP_URL                the https address the app is served from (for the unsubscribe link)
//   NOTIFY_MAX_PER_RUN     optional, default 25, at most 100
// Supabase provides SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY itself.
//
// Logs: counts only. Never an address, a name or a message.
import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import { configFromEnv, liveProblem, runBatch, sameSecret, type Row } from "./lib.ts";

Deno.serve(async (req: Request) => {
  const json = (status: number, body: unknown) =>
    new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

  const secret = Deno.env.get("NOTIFY_SECRET") ?? "";
  if (secret.length < 24) return json(500, { error: "NOTIFY_SECRET is not set (24+ characters). Refusing to run." });   // never run unauthenticated
  if (req.method !== "POST") return json(405, { error: "POST only" });
  if (!sameSecret(req.headers.get("x-notify-secret") ?? "", secret)) return json(401, { error: "no" });

  const cfg = configFromEnv((k) => Deno.env.get(k));
  const problem = liveProblem(cfg);
  if (problem) return json(500, { error: problem, hint: "Nothing was claimed or sent." });      // checked BEFORE claiming

  const url = Deno.env.get("SUPABASE_URL"), key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !key) return json(500, { error: "Supabase environment is missing" });
  const sb = createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });

  const summary = await runBatch({
    cfg,
    claim: async (limit) => {
      const { data, error } = await sb.rpc("notify_claim_batch", { p_limit: limit });
      if (error) throw new Error("claim failed");
      return (data ?? []) as Row[];
    },
    mark: async (id, result, err) => {
      await sb.rpc("notify_mark", { p_id: id, p_result: result, p_error: err });
    },
    send: async (r) => {
      const res = await fetch(r.url, r.init);
      await res.body?.cancel();                                                        // the answer is not needed and not logged
      return { status: res.status };
    },
  }).catch(() => null);

  if (!summary) return json(500, { error: "the run failed before it could finish" });
  console.log(JSON.stringify(summary));                                                // counts only
  return json(200, summary);
});
