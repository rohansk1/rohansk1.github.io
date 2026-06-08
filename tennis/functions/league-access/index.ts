// Supabase Edge Function: league-access  (with diagnostic logging)
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";
import { SMTPClient } from "https://deno.land/x/denomailer@1.6.0/mod.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY  = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const GMAIL_USER   = "rohanskumar.ai@gmail.com";          // sender
const GMAIL_PASS   = Deno.env.get("GMAIL_APP_PASSWORD") ?? ""; // app password (secret)
const NOTIFY_TO    = "rohankumar8551@gmail.com";          // who gets the request
const FUNCTION_URL = `${SUPABASE_URL}/functions/v1/league-access`;

const admin = createClient(SUPABASE_URL, SERVICE_KEY);

async function sendMail(to: string, subject: string, html: string) {
  console.log(`sendMail -> connecting to Gmail (app-password length=${GMAIL_PASS.length})`);
  const client = new SMTPClient({
    connection: { hostname: "smtp.gmail.com", port: 465, tls: true, auth: { username: GMAIL_USER, password: GMAIL_PASS } },
  });
  await client.send({ from: `RSK Tennis League <${GMAIL_USER}>`, to, subject, html });
  await client.close();
  console.log(`sendMail -> sent to ${to}`);
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
  console.log(`request: ${req.method} ${url.pathname}${url.search}`);

  // ----- one-click approve -----
  if (req.method === "GET" && url.searchParams.get("action") === "approve") {
    const id = url.searchParams.get("id");
    const token = url.searchParams.get("token");
    if (!id || !token) return page("Invalid link.");
    const { data: row } = await admin.from("join_requests").select("*").eq("id", id).maybeSingle();
    if (!row || row.token !== token) return page("Invalid or expired link.");
    if (row.status === "approved") return page(`${row.email} is already approved.`);
    await admin.from("allowed_emails").upsert({ email: String(row.email).toLowerCase() }, { onConflict: "email" });
    await admin.from("join_requests").update({ status: "approved" }).eq("id", id);
    try {
      await sendMail(row.email, "You're in — RSK Tennis League",
        `<p>You've been approved for the tennis league. Head to <a href="https://rohanskumar.com/tennis">rohanskumar.com/tennis</a> and sign in with this email.</p>`);
    } catch (e) { console.error("approve-email failed:", (e as Error)?.message ?? e); }
    return page(`Approved ${row.email}. They can sign in now.`);
  }

  // ----- notify (Database Webhook POSTs the new join_requests row) -----
  if (req.method === "POST") {
    let body: { record?: { id?: string } } = {};
    try { body = await req.json(); } catch (e) { console.log("no JSON body:", (e as Error)?.message); }
    console.log("webhook body:", JSON.stringify(body));

    const recId = body?.record?.id;
    console.log("record id:", recId);
    if (!recId) return new Response("ignored: no record id", { status: 200 });

    const { data: row, error: selErr } = await admin.from("join_requests").select("*").eq("id", recId).maybeSingle();
    console.log("looked up row:", JSON.stringify(row), "selectError:", selErr?.message ?? "none");
    if (!row || row.status !== "pending") return new Response("ignored: no pending row", { status: 200 });

    const approveUrl = `${FUNCTION_URL}?action=approve&id=${row.id}&token=${row.token}`;
    try {
      await sendMail(NOTIFY_TO, `Tennis League: ${row.email} wants to join`,
        `<p><b>${row.email}</b> requested access to the tennis league.</p>` +
        `<p><a href="${approveUrl}" style="display:inline-block;background:#c8f04d;color:#0b0b06;padding:11px 18px;border-radius:8px;text-decoration:none;font-weight:700">✓ Approve ${row.email}</a></p>` +
        `<p style="color:#888;font-size:12px">Ignore this email to deny — nothing happens unless you click Approve.</p>`);
      return new Response("ok: emailed", { status: 200 });
    } catch (e) {
      console.error("SMTP FAILED:", (e as Error)?.message ?? String(e));
      return new Response("smtp error: " + ((e as Error)?.message ?? e), { status: 500 });
    }
  }

  return new Response("league-access up", { status: 200 });
});
