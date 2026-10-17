# PugLogs report relay

Receives error reports from the PugLogs app ("Send to developer") and posts them to a private
Discord channel, with the full report attached. The Discord webhook stays secret on Cloudflare;
the public app only knows the relay's address.

Limits: 3 reports per minute per address, 300 KB per report, and Discord mentions are disabled.

## One-time setup

1. **Discord webhook** - in your server: make a private channel (e.g. `#bug-reports`, visible only
   to you), then *Edit Channel -> Integrations -> Webhooks -> New Webhook -> Copy Webhook URL*.
   Treat that address like a password: don't paste it anywhere except step 3.
2. **Cloudflare** - create a free account at dash.cloudflare.com.
3. **Deploy** (Node.js is needed; `npx` downloads Cloudflare's `wrangler` tool):

   ```bash
   cd ~/Desktop/PugLogs/relay
   npx wrangler login
   npx wrangler deploy
   npx wrangler secret put DISCORD_WEBHOOK_URL
   ```

   The last command asks for the webhook address: paste it there. `deploy` prints the relay's
   address, like `https://puglogs-reports.<your-name>.workers.dev`.
4. **Connect the app** - set `RELAY_URL` in `companion/report.py` to that address plus `/report`,
   then build a new release. The "Send to developer" button appears only when `RELAY_URL` is set.

To test before releasing: `PUGLOGS_REPORT_URL=https://.../report companion/run.sh`, then use
"Send to developer" in the window.

## Changing things later
- New webhook (e.g. the old one leaked): run `npx wrangler secret put DISCORD_WEBHOOK_URL` again.
- Local tests (no Discord needed): `node test.mjs`
