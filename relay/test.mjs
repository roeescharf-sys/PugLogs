// Local test of the relay with a fake Discord: node relay/test.mjs
import assert from "node:assert/strict";
import worker from "./worker.js";

const sent = [];
globalThis.fetch = async (url, init) => {
  const form = init.body;
  sent.push({ url, payload: JSON.parse(form.get("payload_json")), file: await form.get("files[0]").text() });
  return new Response("", { status: 200 });
};

let allowed = 10;
const env = {
  DISCORD_WEBHOOK_URL: "https://discord.example/webhook",
  REPORT_LIMITER: { limit: async () => ({ success: allowed-- > 0 }) },
};
const post = (body, path = "/report", method = "POST") =>
  worker.fetch(new Request(`https://relay.example${path}`, {
    method, body: method === "POST" ? (typeof body === "string" ? body : JSON.stringify(body)) : undefined,
  }), env);

const report = "PugLogs error report\nVersion: 0.9.6\n== Errors this session (1) ==\nTypeError: ...";

let r = await post({ version: "0.9.6", system: "Windows-11", summary: "1 error: TypeError",
  note: "Lookup failed\non a Brewmaster @everyone", contact: "friend#1234", report });
assert.equal(r.status, 200, await r.clone().text());
assert.equal(sent.length, 1);
assert.match(sent[0].payload.content, /PugLogs 0\.9\.6/);
assert.ok(!sent[0].payload.content.includes("@everyone"), "mentions must be defused");
assert.deepEqual(sent[0].payload.allowed_mentions, { parse: [] });
assert.equal(sent[0].file, report);

assert.equal((await post({ report: "hello" })).status, 400);              // not a PugLogs report
assert.equal((await post("not json")).status, 400);
assert.equal((await post({}, "/other")).status, 404);
assert.equal((await post(null, "/report", "GET")).status, 404);
assert.equal((await post({ report: report + "x".repeat(400_000) })).status, 413);
allowed = 0;
assert.equal((await post({ report })).status, 429);                        // rate limit used up
assert.equal(sent.length, 1, "rejected requests must not reach Discord");

const noHook = await worker.fetch(new Request("https://relay.example/report", { method: "POST", body: "{}" }), {});
assert.equal(noHook.status, 500);
console.log("relay tests passed");
