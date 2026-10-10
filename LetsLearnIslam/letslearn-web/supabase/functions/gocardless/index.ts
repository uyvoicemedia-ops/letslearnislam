// ============================================================
// LetsLearn — the only place that talks to GoCardless
// ------------------------------------------------------------
// Three routes, one secret, and a hard rule: the API key never
// leaves this function. A browser cannot create a payment, and
// the database cannot be told a payment succeeded by anyone but
// GoCardless, over a signature we check.
//
//   POST /gocardless/start     a parent sets up their Direct Debit
//   POST /gocardless/webhook   GoCardless tells us what happened
//   POST /gocardless/collect   an admin runs a month's collection
//
// Secrets, set with `supabase secrets set`:
//   GC_ACCESS_TOKEN     the GoCardless API key
//   GC_WEBHOOK_SECRET   the endpoint secret from their dashboard
//   GC_ENVIRONMENT      "live" or "sandbox" (default sandbox)
//   APP_URL             where the parent lands when they come back
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are injected.
//
// WHY THE WEBHOOK IS THE ONLY WRITER OF A STATUS. The parent is
// redirected back to APP_URL when they finish, and it is tempting
// to mark the mandate active there. GoCardless say plainly not to:
// the redirect is a browser doing what it is told, and anyone can
// type that URL. The webhook is signed. So the redirect only ever
// says "thanks, we are checking" and the status comes later, from
// a request we verified.
// ============================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const GC_TOKEN  = Deno.env.get("GC_ACCESS_TOKEN") ?? "";
const GC_SECRET = Deno.env.get("GC_WEBHOOK_SECRET") ?? "";
const GC_BASE   = (Deno.env.get("GC_ENVIRONMENT") ?? "sandbox") === "live"
  ? "https://api.gocardless.com"
  : "https://api-sandbox.gocardless.com";
const APP_URL   = Deno.env.get("APP_URL") ?? "http://localhost:8765/index.html";

const SB_URL = Deno.env.get("SUPABASE_URL")!;
const SB_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

/* The service-role client bypasses RLS. That is the whole reason
   mandates and fee_charges have no client write policy: this is the
   only writer, and it only writes what GoCardless has told it. */
const admin = () => createClient(SB_URL, SB_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });

// ---------- talking to GoCardless ----------

async function gc(path: string, init: RequestInit & { idempotency?: string } = {}) {
  const headers: Record<string, string> = {
    "Authorization": `Bearer ${GC_TOKEN}`,
    "GoCardless-Version": "2015-07-06",
    "Accept": "application/json",
  };
  if (init.body) headers["Content-Type"] = "application/json";
  // A retried collection run must not bill a family twice. The unique
  // index on (payer_id, plan_id, period) is the second line of defence;
  // this is the first, and it is the provider's own.
  if (init.idempotency) headers["Idempotency-Key"] = init.idempotency;

  const res = await fetch(GC_BASE + path, { ...init, headers });
  const text = await res.text();
  let body: any = null;
  try { body = text ? JSON.parse(text) : null; } catch { body = { raw: text }; }
  if (!res.ok) {
    const msg = body?.error?.message ?? res.statusText;
    throw new Error(`GoCardless ${res.status}: ${msg}`);
  }
  return body;
}

// ---------- 1. a parent sets up their Direct Debit ----------

async function start(req: Request) {
  // Who is asking. The anon client with the caller's own JWT answers
  // that without trusting anything in the body.
  const auth = req.headers.get("Authorization") ?? "";
  if (!auth.startsWith("Bearer ")) return json({ error: "not signed in" }, 401);

  const asCaller = createClient(SB_URL, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: auth } },
    auth: { persistSession: false },
  });
  const { data: who } = await asCaller.auth.getUser();
  if (!who?.user) return json({ error: "not signed in" }, 401);

  const db = admin();
  const { data: profile } = await db.from("profiles")
    .select("id, role, full_name, email, school_id")
    .eq("auth_uid", who.user.id).maybeSingle();

  if (!profile) return json({ error: "no profile" }, 403);
  // A child must never reach this. ll_adult_session() guards the
  // database; this guards the provider.
  if (profile.role !== "parent" && profile.role !== "admin") {
    return json({ error: "only a parent sets up a Direct Debit" }, 403);
  }
  if (!profile.school_id) return json({ error: "no school to pay" }, 400);

  // Already set up? Don't send them round again.
  const { data: live } = await db.from("mandates")
    .select("id, status").eq("payer_id", profile.id)
    .eq("school_id", profile.school_id).maybeSingle();
  if (live?.status === "active") return json({ already: true });

  const br = await gc("/billing_requests", {
    method: "POST",
    body: JSON.stringify({
      billing_requests: {
        mandate_request: { scheme: "bacs", currency: "GBP" },
        metadata: { payer_id: profile.id, school_id: profile.school_id },
      },
    }),
  });
  const brId = br.billing_requests.id;

  const flow = await gc("/billing_request_flows", {
    method: "POST",
    body: JSON.stringify({
      billing_request_flows: {
        redirect_uri: `${APP_URL}#dd-done`,
        exit_uri: `${APP_URL}#dd-exit`,
        prefilled_customer: {
          email: profile.email ?? undefined,
          given_name: (profile.full_name ?? "").split(" ")[0] || undefined,
          family_name: (profile.full_name ?? "").split(" ").slice(1).join(" ") || undefined,
        },
        links: { billing_request: brId },
      },
    }),
  });

  await db.from("mandates").upsert({
    school_id: profile.school_id,
    payer_id: profile.id,
    gc_billing_request_id: brId,
    status: "pending",
  }, { onConflict: "payer_id,school_id" });

  return json({ authorisation_url: flow.billing_request_flows.authorisation_url });
}

// ---------- 2. GoCardless tells us what happened ----------

/* HMAC-SHA256 of the RAW body with the endpoint secret, compared in
   constant time. Parse the JSON only after this passes: re-serialising
   changes the bytes and the signature stops matching. */
async function signatureOk(raw: Uint8Array, header: string) {
  if (!header || !GC_SECRET) return false;
  const key = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(GC_SECRET),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, raw));
  const want = [...mac].map(b => b.toString(16).padStart(2, "0")).join("");
  if (want.length !== header.length) return false;
  let diff = 0;
  for (let i = 0; i < want.length; i++) diff |= want.charCodeAt(i) ^ header.charCodeAt(i);
  return diff === 0;
}

const MANDATE_STATE: Record<string, string> = {
  created: "pending", customer_approval_granted: "pending",
  submitted: "submitted", active: "active",
  failed: "failed", cancelled: "cancelled", expired: "expired",
};

const PAYMENT_STATE: Record<string, string> = {
  created: "pending", submitted: "submitted", confirmed: "confirmed",
  paid_out: "paid_out", failed: "failed", cancelled: "cancelled",
  charged_back: "charged_back",
};

async function webhook(req: Request) {
  const raw = new Uint8Array(await req.arrayBuffer());
  const sig = req.headers.get("Webhook-Signature") ?? "";
  if (!await signatureOk(raw, sig)) {
    // 498 is what GoCardless's own SDKs use for this.
    return new Response("bad signature", { status: 498 });
  }

  const body = JSON.parse(new TextDecoder().decode(raw));
  const db = admin();

  // Delivery is at-least-once, so every handler has to be safe to run
  // twice. Writing the event id first and ignoring a duplicate is the
  // cheapest way to get that.
  for (const ev of body.events ?? []) {
    const seen = await db.from("webhook_events")
      .insert({ id: ev.id, resource_type: ev.resource_type, action: ev.action })
      .select("id").maybeSingle();
    if (seen.error && seen.error.code === "23505") continue;   // already done

    if (ev.resource_type === "mandates") {
      const id = ev.links?.mandate;
      const state = MANDATE_STATE[ev.action];
      if (id && state) {
        await db.from("mandates").update({
          status: state,
          failed_reason: state === "failed" || state === "cancelled"
            ? (ev.details?.description ?? null) : null,
        }).eq("gc_mandate_id", id);
      }
    }

    if (ev.resource_type === "billing_requests" && ev.action === "fulfilled") {
      // the mandate now exists; tie its id to the row we made at /start
      const brId = ev.links?.billing_request;
      const mandateId = ev.links?.mandate;
      if (brId && mandateId) {
        await db.from("mandates")
          .update({ gc_mandate_id: mandateId, status: "submitted" })
          .eq("gc_billing_request_id", brId);
      }
    }

    if (ev.resource_type === "payments") {
      const id = ev.links?.payment;
      const state = PAYMENT_STATE[ev.action];
      if (id && state) {
        await db.from("fee_charges").update({
          status: state,
          failed_reason: state === "failed" || state === "charged_back"
            ? (ev.details?.description ?? null) : null,
        }).eq("gc_payment_id", id);
      }
    }
  }

  return new Response(null, { status: 204 });
}

// ---------- 3. an admin runs a collection ----------

async function collect(req: Request) {
  const auth = req.headers.get("Authorization") ?? "";
  if (!auth.startsWith("Bearer ")) return json({ error: "not signed in" }, 401);

  const asCaller = createClient(SB_URL, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: auth } },
    auth: { persistSession: false },
  });
  const { data: who } = await asCaller.auth.getUser();
  if (!who?.user) return json({ error: "not signed in" }, 401);

  const db = admin();
  const { data: me } = await db.from("profiles")
    .select("id, role, school_id").eq("auth_uid", who.user.id).maybeSingle();
  if (!me || me.role !== "admin") return json({ error: "admins only" }, 403);

  const { plan_id, period, charge_date, dry_run } = await req.json();
  if (!plan_id || !period) return json({ error: "plan_id and period are required" }, 400);

  const { data: plan } = await db.from("fee_plans")
    .select("*").eq("id", plan_id).eq("school_id", me.school_id).maybeSingle();
  if (!plan) return json({ error: "no such plan" }, 404);

  const { data: live } = await db.from("mandates")
    .select("id, payer_id, gc_mandate_id")
    .eq("school_id", me.school_id).eq("status", "active");

  // who has already been charged for this period
  const { data: done } = await db.from("fee_charges")
    .select("payer_id").eq("plan_id", plan_id).eq("period", period);
  const already = new Set((done ?? []).map(d => d.payer_id));

  const due = (live ?? []).filter(m => m.gc_mandate_id && !already.has(m.payer_id));

  if (dry_run) {
    return json({ would_charge: due.length, skipped: already.size,
                  amount_pence: plan.amount_pence, period });
  }

  const results: any[] = [];
  for (const m of due) {
    // the row first, so a payment that succeeds at GoCardless and then
    // fails to reach us is still visible rather than silently lost
    const { data: row, error } = await db.from("fee_charges").insert({
      school_id: me.school_id, payer_id: m.payer_id, plan_id,
      mandate_id: m.id, amount_pence: plan.amount_pence,
      currency: plan.currency, period, charge_date: charge_date ?? null,
      status: "pending",
    }).select("id").single();

    if (error) {                 // unique (payer_id, plan_id, period) caught it
      results.push({ payer: m.payer_id, skipped: "already charged" });
      continue;
    }

    try {
      const pay = await gc("/payments", {
        method: "POST",
        idempotency: `${plan_id}:${period}:${m.payer_id}`,
        body: JSON.stringify({
          payments: {
            amount: plan.amount_pence,
            currency: plan.currency,
            charge_date: charge_date ?? undefined,
            description: `${plan.name} — ${period}`,
            metadata: { period, payer_id: m.payer_id },
            links: { mandate: m.gc_mandate_id },
          },
        }),
      });
      await db.from("fee_charges")
        .update({ gc_payment_id: pay.payments.id, status: "submitted" })
        .eq("id", row.id);
      results.push({ payer: m.payer_id, payment: pay.payments.id });
    } catch (e) {
      await db.from("fee_charges")
        .update({ status: "failed", failed_reason: String(e).slice(0, 300) })
        .eq("id", row.id);
      results.push({ payer: m.payer_id, error: String(e) });
    }
  }

  return json({ charged: results.filter(r => r.payment).length, results });
}

// ---------- the door ----------

Deno.serve(async (req) => {
  const path = new URL(req.url).pathname.replace(/^\/gocardless/, "") || "/";
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: {
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Headers": "authorization, content-type",
      "Access-Control-Allow-Methods": "POST, OPTIONS",
    } });
  }
  try {
    if (req.method === "POST" && path === "/start")   return await start(req);
    if (req.method === "POST" && path === "/webhook") return await webhook(req);
    if (req.method === "POST" && path === "/collect") return await collect(req);
    return json({ error: "not found" }, 404);
  } catch (e) {
    console.error(e);
    return json({ error: String(e) }, 500);
  }
});
