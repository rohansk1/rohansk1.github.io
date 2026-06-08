// Supabase Edge Function: league-access
// -------------------------------------------------------------------------
// Two jobs:
//   1) NOTIFY  — when someone requests access (POST from a Database Webhook on
//      `join_requests` INSERT), email Rohan from the Gmail with an Approve link.
//   2) APPROVE — when Rohan clicks that link (GET ?action=approve&id&token),
//      add the email to `allowed_emails` so they can sign in.
//
// DEPLOY NOTES:
//   * Deploy with "Verify JWT" = OFF (the approve link is opened from an email
//     with no auth header; spoofing is blocked by re-reading the DB + a random
//     per-request token).
//   * Set one secret in the dashboard: GMAIL_APP_PASSWORD (the Gmail app password).
//     SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are injected automatically.
// -------------------------------------------------------------------------
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";
import { SMTPClient } from "https://deno.land/x/denomailer@1.6.0/mod.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY  = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const GMAIL_USER   = "rohanskumar.ai@gmail.com";          // sender
const GMAIL_PASS   = Deno.env.get("GMAIL_APP_PASSWORD")!; // app password (secret)
const NOTIFY_TO    = "rohankumar8551@gmail.com";          // who gets the request
const FUNCTION_URL = `${SUPABASE_URL}/functions/v1/league-access`;

const admin = createClient(SUPABASE_URL, SERVICE_KEY);

async function sendMail(to: string, subject: string, html: string) {
  const client = new SMTPClient({
    connection: { hostname: "smtp.gmail.com", port: 465, tls: true, auth: { username: GMAIL_USER, password: GMAIL_PASS } },
  });
  await client.send({ from: `RSK Tennis League <${GMAIL_USER}>`, to, subject, html });
  await client.close();
}

function page(msg: string) {
  return new Response(
    `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">` +
    `<body style="font-family:sans-serif;background:#06060a;color:#e2e0dd;text-align:center;padding:64px 20px">` +
    `<h2 style="color:#c8f04d">🎾 ${msg}</h2></body>`,
    { headers: { "content-type": "text/html; charset=utf-8" } },
  );
}

Deno.serve(async (req) => {
  const url = new URL(req.url);

  // ----- one-click approve (Rohan clicks the link in the email) -----
  if (req.method === "GET" && url.searchParams.get("action") === "approve") {
    const id = url.searchParams.get("id");
    const token = url.searchParams.get("token");
    if (!id || !token) return page("Invalid link.");

    const { data: row } = await admin.from("join_requests").select("*").eq("id", id).maybeSingle();
    if (!row || row.token !== token) return page("Invalid or expired link.");
    if (row.status === "approved") return page(`${row.email} is already approved.`);

    await admin.from("allowed_emails").upsert({ email: String(row.email).toLowerCase() }, { onConflict: "email" });
    await admin.from("join_requests").update({ status: "approved" }).eq("id", id);

    // let the requester know they're in
    try {
      await sendMail(row.email, "You're in — RSK Tennis League",
        `<p>You've been approved for the tennis league. Head to ` +
        `<a href="https://rohanskumar.com/tennis">rohanskumar.com/tennis</a> and sign in with this email.</p>`);
    } catch (_e) { /* non-fatal */ }

    return page(`Approved ${row.email}. They can sign in now.`);
  }

  // ----- notify (Database Webhook POSTs the new join_requests row) -----
  if (req.method === "POST") {
    let body: { record?: { id?: string } } = {};
    try { body = await req.json(); } catch (_e) { /* ignore */ }
    const recId = body?.record?.id;
    if (!recId) return new Response("ignored", { status: 200 });

    // Re-read the authoritative row (defeats spoofed payloads).
    const { data: row } = await admin.from("join_requests").select("*").eq("id", recId).maybeSingle();
    if (!row || row.status !== "pending") return new Response("ignored", { status: 200 });

    const approveUrl = `${FUNCTION_URL}?action=approve&id=${row.id}&token=${row.token}`;
    await sendMail(NOTIFY_TO, `Tennis League: ${row.email} wants to join`,
      `<p><b>${row.email}</b> requested access to the tennis league.</p>` +
      `<p><a href="${approveUrl}" style="display:inline-block;background:#c8f04d;color:#0b0b06;` +
      `padding:11px 18px;border-radius:8px;text-decoration:none;font-weight:700">✓ Approve ${row.email}</a></p>` +
      `<p style="color:#888;font-size:12px">Ignore this email to deny — nothing happens unless you click Approve.</p>`);
    return new Response("ok", { status: 200 });
  }

  return new Response("league-access up", { status: 200 });
});
