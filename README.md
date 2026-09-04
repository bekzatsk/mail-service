# Mail Service

A small Ruby service that other projects call to send things: email through
their own SMTP credentials, and Telegram messages through their own bot.

The point is that a calling project holds one API key and nothing else. No SMTP
password in its config, no bot token, no chat id. All of that lives here, so it
can change without a deploy on their side.

## How it fits together

Three levels, and everything else follows from them:

```
organization          a tenant. The boundary that mail logs are scoped to.
  └── client          one set of SMTP credentials + one API key
        ├── mail      POST /send            → SMTP → mail_logs
        └── bots      POST /telegram/...    → Telegram
```

An **organization** is a tenant — a company, a product. It exists to group
clients and to scope the mail log.

A **client** is one API key with one set of SMTP credentials behind it. A single
organization usually has several: `no-reply@` for transactional mail,
`billing@` for invoices. Each gets its own key, so one can be revoked without
touching the others.

The **API key** is what a calling project stores. It is created when the client
is, and it is the only credential that project ever needs.

Two scopes matter and they are not the same, which is easy to get wrong:

- **Mail logs are per organization.** Any client key in an organization can read
  the whole organization's send history, including other clients' mail. If two
  tenants must not see each other's logs, they need separate organizations, not
  separate clients.
- **Telegram is per client.** Bots, chats, commands and message history belong
  to the client, not the organization. A key sees only its own bots.

A second key exists for administration: the **master key**, set in `.env`. It
creates organizations and clients and backs the admin console. It is not for
applications.

## Sending mail

```bash
curl -X POST https://your-host/send \
  -H "X-Api-Key: <client-key>" -H "Content-Type: application/json" \
  -d '{"to": "someone@example.com", "subject": "Hello", "body": "<h1>Hi</h1>"}'
```

The service loads that client's SMTP row, decrypts the password, and connects.
Port 465 means implicit SSL; anything else negotiates STARTTLS.

The body's format is auto-detected: if it looks like HTML, it is sent as HTML
with a stripped plaintext part alongside, so text-only readers get something
sensible. Pass `isHtml` to decide explicitly instead.

Every attempt is written to `mail_logs`, delivered or failed, with the SMTP
error when there was one. That write is deliberately best-effort — if logging
fails the send still counts, because losing a log entry is better than losing a
delivered message.

`to`, `cc` and `bcc` accept a string or an array. `replyTo`, `from`, `priority`
(`high`/`normal`/`low`) and arbitrary `headers` are optional.

Read the history back with `GET /logs` — remember it covers the whole
organization, not just this key.

## Telegram

The same client key reaches a second gateway. It has an outbound half and an
inbound half, and they are configured independently.

### Outbound: routes

A project that reports errors to one group and daily figures to another would
normally hard-code two chat ids. Then a group gets recreated and every project
needs a change.

Instead, name the destinations once — `errors`, `reports` — and send the name:

```bash
curl -X POST https://your-host/telegram/messages \
  -H "X-Api-Key: <client-key>" -H "Content-Type: application/json" \
  -d '{"route": "errors", "text": "NullPointerException in OrderService"}'
```

Which group is behind `errors` is decided here, in the console. Repoint it and
every caller follows without a deploy. `chatId` still works when you want to
address a chat directly.

Route names are lowercased on write, so `Errors` and `errors` are the same
route. A name is unique per bot. If the same name exists on two bots the send
returns `409` and asks you to name the bot, rather than guessing which group an
error report was meant for.

### Inbound: two transports

Nothing above needs a transport — sending is a plain HTTPS call to Telegram made
inside the request. The transport question only concerns updates coming *in*:
someone writing to the bot.

Each bot is on one of two:

**Webhook** — Telegram POSTs to `/telegram/webhook/:bot_id`. No threads, nothing
to keep warm. That route is the one unauthenticated endpoint in the service, by
necessity: Telegram cannot send our `X-Api-Key`. What authenticates it is a
per-bot secret token, issued at registration, echoed back by Telegram in a
header and compared in constant time.

**Polling** — a thread inside the app process runs `getUpdates` in a loop.

Webhook is the right answer under Passenger, and the reason is worth stating
because it bites silently. Passenger suspends an idle instance, and the polling
thread dies with it: the bot goes quiet until the next HTTP request happens to
wake the app. Under load Passenger runs *several* processes, each starts its own
listener, and Telegram answers duplicate consumers with `409 Conflict` and drops
updates. Neither is fixable from inside the process.

Switch a bot over from the console, or:

```bash
curl -X POST https://your-host/telegram/bots/11/webhook \
  -H "X-Api-Key: <client-key>" -H "Content-Type: application/json" \
  -d '{"baseUrl": "https://your-host"}'
```

Set `PUBLIC_BASE_URL` in `.env` so the registered URL is right; without it the
service falls back to whatever the request claims, which is a guess behind a
proxy. Transport is per bot, so bots move one at a time and a local bot can keep
polling while production does not.

### Inbound: where updates go

An update reaches exactly one place.

If the text names a **slash command** that exists in `telegram_commands` and is
enabled, it goes to that command's `handler_url`.

Everything else — ordinary text, and slash commands with no row — goes to the
bot's **message handler**, if one is set. Without one, a plain message is written
to `telegram_messages` and stops there: visible in the console, invisible to your
project.

Both handlers get the same payload and answer the same way:

```json
{
  "chatId": -1001234567890, "chatType": "supergroup",
  "userId": 55512345, "username": "bekzat",
  "text": "where is my order?",
  "command": null, "args": null,
  "messageId": 901, "botId": 11, "botName": "acme-support"
}
```

`command` is `null` for ordinary text and carries the name for a slash nothing
claimed — that is how you tell a question from a typo. Reply
`{"text": "Order #148 is on its way"}` and it is sent to the chat; reply with no
text and the bot stays silent, which is the right outcome for most messages.

Handlers are called with `X-Handler-Secret` so your endpoint can verify the
caller.

Registered commands are pushed to Telegram's command menu automatically
(`setMyCommands`) whenever you add, edit or remove one.

### Setting one up

From nothing to a bot that posts errors into a group and answers questions.
Every step has a console equivalent — **Telegram → Bots / Chats** — so the curl
is here to show what the console does, not because you have to type it.

**1. Create the bot.** Talk to [@BotFather](https://t.me/BotFather) in Telegram,
`/newbot`, and keep the token it gives you. That token is the bot; anyone holding
it controls it.

**2. Connect it to this service.** The token is verified against Telegram before
anything is stored, and stored encrypted:

```bash
curl -X POST https://your-host/telegram/bots \
  -H "X-Api-Key: <client-key>" -H "Content-Type: application/json" \
  -d '{"name": "acme-support", "botToken": "123456:AA...", "isDefault": true}'
```

`name` is your own label and must be unique for the client. The response carries
the bot's numeric `id` — the next steps need it.

**3. Put the bot in the group** and give it permission to post. For a group
where it should read messages too, turn off privacy mode in BotFather
(`/setprivacy` → Disable), otherwise it only sees messages addressed to it.

**4. Find the group's chat id.** It is negative for groups and supergroups.
Easiest is to forward a message from the group to
[@userinfobot](https://t.me/userinfobot). Or, once the bot is in the group and
inbound is running, write anything there and read the id off
**Telegram → Messages** in the console.

**5. Register the group and name a route:**

```bash
curl -X POST https://your-host/telegram/chats \
  -H "X-Api-Key: <client-key>" -H "Content-Type: application/json" \
  -d '{"botId": 11, "chatId": -1001234567890, "chatType": "supergroup",
       "title": "Acme errors", "routeName": "errors"}'
```

Repeat for every destination — `reports`, `deploys`, whatever the project needs.
From here on, callers use the name and never the id.

**6. Switch it to webhook** so inbound survives the app going idle:

```bash
curl -X POST https://your-host/telegram/bots/11/webhook \
  -H "X-Api-Key: <client-key>" -H "Content-Type: application/json" \
  -d '{"baseUrl": "https://your-host"}'
```

Skip this if the bot only ever sends and nobody talks to it — outbound needs no
transport at all.

**7. Point inbound at your project**, if you want to receive anything:

```bash
curl -X PATCH https://your-host/telegram/bots/11 \
  -H "X-Api-Key: <client-key>" -H "Content-Type: application/json" \
  -d '{"messageHandlerUrl": "https://your-project.example/telegram/message",
       "messageHandlerSecret": "<shared secret>"}'
```

Add slash commands with `POST /telegram/commands` if some inputs deserve their
own endpoint; anything they do not claim falls through to the handler above.

**8. Send something:**

```bash
curl -X POST https://your-host/telegram/messages \
  -H "X-Api-Key: <client-key>" -H "Content-Type: application/json" \
  -d '{"route": "errors", "text": "NullPointerException in OrderService"}'
```

If it does not arrive, the useful checks in order: `GET /telegram/routes` shows
whether the name resolves, `GET /telegram/bots/11/webhook` shows whether Telegram
can reach you (a climbing `pendingUpdateCount` and a `lastErrorMessage` mean it
cannot), and **Telegram → Messages** in the console shows what was attempted and
why it failed.

### What a calling project actually sends

Everything above is setup, done once. Day to day a project makes three kinds of
request and answers one. This is the whole surface it needs — the rest of
[API_README.md](API_README.md) is for whoever administers the service.

**Send to a named destination.** The common case:

```http
POST /telegram/messages
X-Api-Key: <client-key>
Content-Type: application/json

{"route": "errors", "text": "NullPointerException in OrderService"}
```

```json
{ "id": 42, "telegramMessageId": 902, "status": "sent" }
```

Optional: `parseMode` (`HTML` or `MarkdownV2`), `replyToMessageId`,
`disableNotification`. Use `chatId` instead of `route` to address a chat
directly.

What can come back instead:

| Status | Body | Meaning |
|--------|------|---------|
| `400` | `Missing required field: route or chatId` | neither was given |
| `404` | `Unknown route 'errors'` | the name is not registered — check `GET /telegram/routes` |
| `409` | `Route 'errors' exists on more than one bot …` | add `botId`; the service will not guess |
| `400` | `Bot is disabled` | the bot is switched off in the console |
| `500` | `Failed to send message` + `details` | Telegram rejected it; `details` carries its reason |
| `403` | `Invalid API key` | wrong or revoked client key |

**Send mail.** Same key, same shape:

```http
POST /send
X-Api-Key: <client-key>

{"to": "someone@example.com", "subject": "Hello", "body": "<h1>Hi</h1>"}
```

```json
{ "message": "Email sent successfully" }
```

Failures answer `500` with `details` holding the SMTP error. Either way the
attempt is in `mail_logs`.

**Answer an inbound message.** Your `messageHandlerUrl` (and any command's
`handler_url`) receives a POST with `X-Handler-Secret` and the payload shown
under [Inbound: where updates go](#inbound-where-updates-go). Answer within ten
seconds:

```json
{ "text": "Order #148 is on its way", "parseMode": "HTML" }
```

Return `{}` — or anything with no `text` — and the bot says nothing. That is the
normal answer for a message that does not need a reply.

**Look up the destinations**, if the project wants to check its own config at
boot rather than fail at the first send:

```http
GET /telegram/routes
X-Api-Key: <client-key>
```

```json
{ "routes": [
  { "route": "errors", "chatId": -1001234567890, "title": "Acme errors",
    "chatType": "supergroup", "botId": 11, "botName": "acme-support" }
] }
```

## Admin console

A web console at **`/ui/`** (`/` redirects there). Plain HTML, CSS and ES
modules served straight from `public/ui` — no Node, no build step, nothing to
compile before deploying, because the production target is shared hosting.

Unlock it with the `MASTER_API_KEY` and manage:

- **Organizations** — create, rename, re-slug, delete
- **Clients & keys** — issue keys, edit SMTP config, test stored credentials, rotate or revoke
- **Mail logs** — filter by organization, client, status or text; inspect the full envelope and the delivery error
- **Telegram** — bots and their transport, routes, commands, chats, message history
- **Send test** — compose a message through any client key

The console keeps the master key in `sessionStorage`, or `localStorage` if you
tick "keep me signed in", and sends it as `X-Api-Key`. It can read every client
key, so unlock it only on a machine you trust and only over HTTPS.

## Setup

Requirements: Ruby >= 3.0, Bundler, MySQL, OpenSSL.

```bash
git clone <repo-url> mail-service
cd mail-service
bundle install
cp .env.example .env
```

| Variable           | What it is                                      |
|--------------------|-------------------------------------------------|
| `DB_HOST` … `DB_PASS` | MySQL connection                             |
| `ENCRYPTION_KEY`   | Derives the AES-256 key for SMTP passwords and bot tokens |
| `MASTER_API_KEY`   | Admin key: organizations, clients, the console   |
| `PUBLIC_BASE_URL`  | Public https origin, used to build the Telegram webhook URL |
| `TELEGRAM_ENABLED` | `false` skips the polling supervisor entirely; webhook bots are unaffected |

Generate the two keys:

```bash
ruby -e "require 'securerandom'; puts SecureRandom.hex(32)"
```

**Rotating `ENCRYPTION_KEY` invalidates every stored SMTP password and bot
token.** They are encrypted with a key derived from it and cannot be recovered.

### Database

Nothing to run by hand. `Services::Migrator` executes on every boot: it creates
the database if missing, tracks what has run in `schema_migrations`, and applies
pending files from `db/migrations/` in order.

One constraint that comes from how it works: each file is split on `;` and
executed statement by statement, so **a single statement must not contain a
semicolon** — no stored procedures, no trigger bodies.

### Running

```bash
bundle exec puma config.ru -p 8080
```

For production on cPanel/Plesk with Passenger see [DEPLOY.md](DEPLOY.md).

A bot left on **polling** needs the worker kept alive between requests — Puma is
fine; Passenger needs `passenger_min_instances ≥ 1`. Bots on **webhook** have no
such requirement, which is why they are the answer there.

## Authentication

One header, `X-Api-Key`, and two kinds of key:

| Key type       | Reaches                                          | Where it comes from            |
|----------------|--------------------------------------------------|--------------------------------|
| **Master key** | all `/organizations*`, `/config*`, `/admin/*`     | `MASTER_API_KEY` in `.env`     |
| **Client key** | `POST /send`, `GET /logs`, all `/telegram/*`      | returned by `POST /config`     |

Missing header → `401`. Wrong key, or the right kind of key on the wrong route →
`403`. A client key cannot reach admin routes and the master key is not a client
key; neither escalates into the other.

No API endpoint is public. The unauthenticated routes are the console's own
static assets under `/ui/`, `/` which redirects there, and
`POST /telegram/webhook/:bot_id`, which authenticates on Telegram's secret token
instead.

## Quick start

```bash
# 1. An organization (master key)
curl -X POST http://localhost:8080/organizations \
  -H "X-Api-Key: $MASTER" -H "Content-Type: application/json" \
  -d '{"name": "My Company"}'

# 2. A client — this returns the key the project will use (master key)
curl -X POST http://localhost:8080/config \
  -H "X-Api-Key: $MASTER" -H "Content-Type: application/json" \
  -d '{"organization_id": 1, "smtp_host": "smtp.example.com", "smtp_port": 587,
       "smtp_user": "you@example.com", "smtp_pass": "app-password",
       "from_address": "you@example.com", "test_before_save": true}'

# 3. Send (client key)
curl -X POST http://localhost:8080/send \
  -H "X-Api-Key: $CLIENT" -H "Content-Type: application/json" \
  -d '{"to": "recipient@example.com", "subject": "Hello", "body": "<h1>Hi</h1>"}'

# 4. Read the log (client key, whole organization)
curl http://localhost:8080/logs -H "X-Api-Key: $CLIENT"
```

`test_before_save: true` verifies the SMTP credentials before storing them, so a
typo fails at registration rather than at the first send.

Full endpoint reference: [API_README.md](API_README.md).

## Layout

```
app.rb                    Sinatra routes; every handler returns a Rack triple
config.ru                 loads .env → migrations → Telegram supervisor → app
app/
  handlers/               HTTP shape only: parse, validate, status codes
    organization_handler  /organizations
    config_handler        /config — client registration and SMTP test
    mail_handler          /send, /logs
    telegram_handler      /telegram/*
    admin_handler         /admin/* — the console's backend
  middleware/
    api_key_middleware    decides public / master / client for every request
  services/               business logic and side effects
    database              single mysql2 client, prepared statements
    encryption_service    AES-256-CBC for SMTP passwords and bot tokens
    secure_compare        constant-time comparison, used by every secret check
    mail_service          the mail gem, plus logging
    smtp_test_service     connect + auth, 10s timeout
    migrator              runs on every boot
    telegram_service      Telegram Bot API client
    telegram_update_processor   what happens to an inbound update
    telegram_bot_listener       polling transport
    telegram_bot_supervisor     one thread per polling bot
    telegram_command_sync       pushes the command menu to Telegram
db/migrations/            NNN_*.sql, applied in order on boot
public/ui/                the admin console — static, no build step
test/                     checks that run without a database
script/                   repository checks used by CI
```

## Development

Every check runs locally and none needs a database:

```bash
ruby test/middleware_routes_test.rb          # who may reach which route
ruby test/secure_compare_test.rb             # constant-time comparison
ruby test/telegram_command_parsing_test.rb   # command vs. plain message
ruby test/ci_config_test.rb                  # the pipeline's own invariants
sh script/check-ui-modules.sh                # console modules parse, no unsafe sinks
sh script/check-secrets.sh                   # nothing credential-shaped is tracked

npm i --no-save playwright@1.62.1 && npx playwright install chromium
node test/ui_smoke_test.mjs                  # the console in a real browser
```

To work on the console without a database:

```bash
node test/support/mock_api.mjs 8117
```

Serves it against fixtures at <http://127.0.0.1:8117/ui/>; the master key is
`test-master-key`.

## CI/CD

[`.flux-ci.yml`](.flux-ci.yml) runs on [Flux CI](https://flux.innlab.kz/docs/pipeline),
which imports the file from the repository on first open, on "Sync from repo",
and on any push that touches it.

| Stage  | Job               | What it proves |
|--------|-------------------|----------------|
| verify | `ruby-syntax`     | every `.rb` and `config.ru` parses |
| verify | `pipeline-config` | the pipeline's own invariants — see below |
| verify | `console-modules` | console modules parse, no `innerHTML`/`eval`, no missing asset |
| verify | `secret-scan`     | no `.env`, credential, live API key or private key is tracked |
| test   | `route-auth`      | the route/key matrix, constant-time compare, command parsing |
| test   | `console-smoke`   | the console boots in Chromium, every view renders, no overflow at 320–1920px |
| deploy | `deploy-ftps`     | **manual** — FTPS mirror to the host, then verifies the live service |

`pipeline-config` exists because nothing else type-checks a pipeline and its
mistakes only surface on a runner, against production. It asserts, among other
things, that no `lftp` invocation spans more than one line — a folded YAML block
once turned the deploy's `mirror` into a bare `mirror --reverse`, which uploaded
the whole workspace into the FTP account root.

### Deploy

`deploy-ftps` is `when: manual`, so a push builds and tests without shipping
anything; someone presses play.

| Name | Kind | Notes |
|------|------|-------|
| `FLUX_FTP_USER` | org secret | the shared FTP account for this host |
| `FLUX_FTP_PASS` | org secret | reaches every domain on the host — keep it protected |
| `FLUX_FTP_HOST` | org secret | the file carries a fallback, the secret wins |
| `MAIL_REMOTE_DIR` | variable | the FTP directory, a domain name with no `httpdocs` level — **not** necessarily the domain the service answers on |
| `MAIL_SITE_URL` | variable | the deploy refuses to run without it |

Every one is guarded at the top of the job. A protected secret arrives as an
empty string on a non-protected ref *and still overrides the fallback in the
file*, so `FLUX_FTP_USER is empty` means either "not defined" or "this ref is
not protected".

Two consequences of deploying over FTPS:

- **Gems are not shipped.** There is no `bundle install` at the far end. After a
  `Gemfile` change, run it on the host once.
- **Nothing is deleted.** The mirror never passes `--delete`, because the host
  holds `.env`, `vendor/bundle` and `tmp/`, none of which are in this repo. A
  file removed from the repo stays on the server until removed by hand.

Before uploading a byte the job checks that `MAIL_REMOTE_DIR` exists and holds a
`config.ru`. It finishes by checking the live service: `/organizations` must
answer `401` and `/ui/` must serve the console. A mirror that uploaded fine but
left the old process running is still a failed deploy.

## Security

- SMTP passwords and bot tokens are AES-256-CBC encrypted before storage, with a
  random IV per record prepended to the ciphertext. The key is SHA-256 of
  `ENCRYPTION_KEY`.
- API keys are `SecureRandom.hex(32)`. The master key and the Telegram webhook
  token are compared in constant time, through one shared implementation.
- `GET /admin/clients` returns client API keys in plaintext. The console needs
  them to act on a client's behalf; anyone holding the master key already has
  full control. Keep the console behind HTTPS and off shared machines.
- The console renders API data through `textContent` only — never `innerHTML` —
  so a stored subject line or an SMTP error cannot become markup. CI enforces it.
- Never commit `.env`. CI fails the build if anything credential-shaped is
  tracked.

## License

MIT
