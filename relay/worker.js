// PugLogs report relay (Cloudflare Worker).
//
// The PugLogs app sends error reports here; this forwards each one to a private Discord
// channel as a message with the report attached. The Discord webhook address is stored as a
// Worker secret (DISCORD_WEBHOOK_URL), so it never appears in the public app.
//
// Abuse limits: POST /report only, JSON only, at most MAX_BYTES, and a per-address rate limit
// (REPORT_LIMITER binding, see wrangler.toml). Discord mentions are disabled, so a report
// can't ping @everyone.

const MAX_BYTES = 300_000;
const MAX_FIELD = 300;

const reply = (status, message) =>
  new Response(JSON.stringify({ ok: status === 200, message }), {
    status,
    headers: { "Content-Type": "application/json" },
  });

// One-line field from the app: no line breaks, limited length, no Discord markdown links.
const clean = (value, max = MAX_FIELD) =>
  String(value ?? "").replace(/[\r\n]+/g, " ").replace(/[`@]/g, "'").slice(0, max).trim();

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (request.method !== "POST" || url.pathname !== "/report") {
      return reply(404, "Not found");
    }
    if (!env.DISCORD_WEBHOOK_URL) {
      return reply(500, "Relay not configured");
    }

    const address = request.headers.get("CF-Connecting-IP") || "unknown";
    if (env.REPORT_LIMITER) {
      const { success } = await env.REPORT_LIMITER.limit({ key: address });
      if (!success) return reply(429, "Too many reports - please wait a minute and try again.");
    }

    const length = Number(request.headers.get("Content-Length") || 0);
    if (length > MAX_BYTES) return reply(413, "Report too large");
    const raw = await request.text();
    if (raw.length > MAX_BYTES) return reply(413, "Report too large");

    let data;
    try {
      data = JSON.parse(raw);
    } catch {
      return reply(400, "Not JSON");
    }
    if (typeof data.report !== "string" || !data.report.startsWith("PugLogs error report")) {
      return reply(400, "Not a PugLogs report");
    }

    const version = clean(data.version, 40) || "?";
    const system = clean(data.system, 120) || "?";
    const summary = clean(data.summary, 300) || "no errors recorded";
    const note = clean(data.note, 1000);
    const contact = clean(data.contact, 100);
    const content = [
      `**PugLogs ${version}** on ${system}`,
      `Errors: ${summary}`,
      note && `What happened: ${note}`,
      contact && `Contact: ${contact}`,
    ].filter(Boolean).join("\n").slice(0, 1900);

    const form = new FormData();
    form.append("payload_json", JSON.stringify({
      content,
      allowed_mentions: { parse: [] },
      attachments: [{ id: 0, filename: "error-report.txt" }],
    }));
    form.append("files[0]", new Blob([data.report], { type: "text/plain" }), "error-report.txt");

    const sent = await fetch(env.DISCORD_WEBHOOK_URL, { method: "POST", body: form });
    if (!sent.ok) return reply(502, `Discord refused the report (${sent.status})`);
    return reply(200, "Report sent - thank you!");
  },
};
