// Sends one e-mail per in-app notification. Called by the database (pg_net) with a Vault-backed secret.
// Provider: Brevo (BREVO_API_KEY) or Resend (RESEND_API_KEY). Also needs EMAIL_FROM (+ optional EMAIL_FROM_NAME, PORTAL_URL).
import { createClient } from "jsr:@supabase/supabase-js@2";

const PORTAL_URL = Deno.env.get("PORTAL_URL") ?? "https://terraviva-organization-portal.vercel.app/";
const FROM = Deno.env.get("EMAIL_FROM") ?? "";
const FROM_NAME = Deno.env.get("EMAIL_FROM_NAME") ?? "Terraviva Portal";
const BREVO = Deno.env.get("BREVO_API_KEY");
const RESEND = Deno.env.get("RESEND_API_KEY");
// Option C (no provider account needed): a Google Apps Script web app that sends through your own Gmail.
const GAS_URL = Deno.env.get("APPS_SCRIPT_URL");
const GAS_SECRET = Deno.env.get("APPS_SCRIPT_SECRET");

const esc = (s: string) => s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));

function render(name: string, title: string, body: string) {
  const html = `<!doctype html><html><body style="margin:0;background:#f4f8f6;font-family:Arial,Helvetica,sans-serif;color:#173b2b">
<table width="100%" cellpadding="0" cellspacing="0"><tr><td align="center" style="padding:24px 12px">
<table width="560" cellpadding="0" cellspacing="0" style="max-width:560px;background:#fff;border-radius:14px;overflow:hidden;border:1px solid #e0e9e3">
<tr><td style="background:#0e5b34;color:#fff;padding:18px 24px;font-size:18px;font-weight:bold;letter-spacing:2px">TERRAVIVA</td></tr>
<tr><td style="padding:24px">
<p style="margin:0 0 6px;color:#68786f;font-size:13px">Hello ${esc(name)},</p>
<h2 style="margin:0 0 12px;font-size:20px">${esc(title)}</h2>
<p style="margin:0 0 22px;font-size:15px;line-height:1.6;white-space:pre-wrap">${esc(body)}</p>
<a href="${esc(PORTAL_URL)}" style="display:inline-block;background:#167b43;color:#fff;text-decoration:none;padding:12px 22px;border-radius:10px;font-weight:bold">Open Terraviva Portal</a>
</td></tr>
<tr><td style="padding:16px 24px;background:#f4f8f6;color:#718078;font-size:12px">Terraviva – Protecting Nature, Empowering Communities.<br>You can turn off email alerts any time in the portal under My Profile.</td></tr>
</table></td></tr></table></body></html>`;
  const text = `Hello ${name},\n\n${title}\n\n${body}\n\nOpen the portal: ${PORTAL_URL}\n\nTerraviva – Protecting Nature, Empowering Communities.`;
  return { html, text };
}

async function deliver(to: string, toName: string, subject: string, html: string, text: string) {
  if (GAS_URL) {
    const r = await fetch(GAS_URL, {
      method: "POST",
      redirect: "follow",
      headers: { "content-type": "text/plain;charset=utf-8" },
      body: JSON.stringify({ secret: GAS_SECRET ?? "", to, subject, html, text, fromName: FROM_NAME }),
    });
    const t = await r.text();
    let j: { ok?: boolean; error?: string } = {};
    try { j = JSON.parse(t); } catch { /* not JSON */ }
    if (!r.ok || !j.ok) throw new Error("Apps Script: " + (j.error ?? t.slice(0, 200)));
    return;
  }
  if (!FROM) throw new Error("EMAIL_FROM secret is not set");
  if (BREVO) {
    const r = await fetch("https://api.brevo.com/v3/smtp/email", {
      method: "POST",
      headers: { "api-key": BREVO, "content-type": "application/json", accept: "application/json" },
      body: JSON.stringify({ sender: { name: FROM_NAME, email: FROM }, to: [{ email: to, name: toName }], subject, htmlContent: html, textContent: text }),
    });
    if (!r.ok) throw new Error("Brevo " + r.status + ": " + (await r.text()).slice(0, 300));
    return;
  }
  if (RESEND) {
    const r = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: "Bearer " + RESEND, "content-type": "application/json" },
      body: JSON.stringify({ from: `${FROM_NAME} <${FROM}>`, to: [to], subject, html, text }),
    });
    if (!r.ok) throw new Error("Resend " + r.status + ": " + (await r.text()).slice(0, 300));
    return;
  }
  throw new Error("No email provider configured (set APPS_SCRIPT_URL + APPS_SCRIPT_SECRET, or BREVO_API_KEY, or RESEND_API_KEY)");
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });
  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const { data: secret } = await db.rpc("email_webhook_secret");
  if (!secret || req.headers.get("x-webhook-secret") !== secret) return new Response("Unauthorized", { status: 401 });

  const payload = await req.json().catch(() => ({}));
  let ids: string[] = [];
  if (payload.flush) {
    // Re-send notifications from the last 3 days that never got an e-mail (e.g. before the provider was configured).
    const since = new Date(Date.now() - 3 * 86400000).toISOString();
    const { data } = await db.from("notifications").select("id").is("emailed_at", null).gte("created_at", since).order("created_at").limit(50);
    ids = (data ?? []).map((x) => x.id);
  } else if (payload.id) ids = [payload.id];

  const results: Record<string, string> = {};
  for (const id of ids) {
    // Atomically claim the notification so it is never e-mailed twice.
    const { data: claimed } = await db.from("notifications").update({ emailed_at: new Date().toISOString(), email_error: null }).eq("id", id).is("emailed_at", null).select().maybeSingle();
    if (!claimed) { results[id] = "skipped"; continue; }
    const { data: p } = await db.from("staff_profiles").select("full_name,official_email,email_notifications,account_status").eq("id", claimed.recipient_id).maybeSingle();
    if (!p?.official_email || !p.email_notifications || p.account_status !== "approved") { results[id] = "skipped (recipient opted out)"; continue; }
    try {
      const { html, text } = render(p.full_name || "colleague", claimed.title, claimed.body);
      await deliver(p.official_email, p.full_name || "", "[Terraviva] " + claimed.title, html, text);
      results[id] = "sent";
    } catch (e) {
      await db.from("notifications").update({ emailed_at: null, email_error: String((e as Error).message).slice(0, 500) }).eq("id", id);
      results[id] = "error: " + (e as Error).message;
    }
  }
  return new Response(JSON.stringify({ results }), { headers: { "content-type": "application/json" } });
});
