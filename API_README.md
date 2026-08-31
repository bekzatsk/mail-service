# Mail Service — API Documentation

Base URL: `http://localhost:8080`

All requests and responses use `Content-Type: application/json`.

---

## Authentication

All authenticated endpoints use the `X-Api-Key` header. There are two key types:

| Key type       | Header value            | Protects                              |
|----------------|-------------------------|---------------------------------------|
| **Master key** | `MASTER_API_KEY` from `.env` | `POST /organizations`, `POST /config` |
| **Client key** | Returned by `POST /config`  | `POST /send`, `GET /logs`             |

```
X-Api-Key: <master-key-or-client-key>
```

There are no public endpoints. `GET /organizations` and `GET /organizations/:id` require the master key, same as `POST /organizations`.

If the header is missing, the API returns `401`. If the key is invalid, it returns `403`.

---

## Endpoints

### POST /organizations

Create a new organization.

**Auth:** Master key (`X-Api-Key: MASTER_API_KEY`)

**Request body:**

| Field  | Type   | Required | Description                                      |
|--------|--------|----------|--------------------------------------------------|
| `name` | string | yes      | Organization name                                |
| `slug` | string | no       | URL-friendly slug (auto-generated from name if omitted) |

**Example request:**

```bash
curl -X POST http://localhost:8080/organizations \
  -H "Content-Type: application/json" \
  -H "X-Api-Key: YOUR_MASTER_KEY" \
  -d '{ "name": "My Company", "slug": "my-company" }'
```

**Success response** — `201 Created`:

```json
{
  "organization": {
    "id": 1,
    "name": "My Company",
    "slug": "my-company",
    "created_at": "2026-04-03 10:00:00"
  },
  "message": "Organization created successfully"
}
```

**Error responses:**

`400` — missing name:

```json
{ "error": "Missing required field: name" }
```

`409` — duplicate slug:

```json
{ "error": "Organization slug 'my-company' already exists" }
```

---

### GET /organizations

List all organizations.

**Auth:** Master key

**Example request:**

```bash
curl http://localhost:8080/organizations \
  -H "X-Api-Key: your-master-api-key"
```

**Success response** — `200 OK`:

```json
{
  "organizations": [
    { "id": 1, "name": "My Company", "slug": "my-company", "created_at": "2026-04-03 10:00:00" },
    { "id": 2, "name": "Another Org", "slug": "another-org", "created_at": "2026-04-03 11:00:00" }
  ]
}
```

---

### GET /organizations/:id

Get a single organization with its client count.

**Auth:** Master key

**Example request:**

```bash
curl http://localhost:8080/organizations/1 \
  -H "X-Api-Key: your-master-api-key"
```

**Success response** — `200 OK`:

```json
{
  "organization": {
    "id": 1,
    "name": "My Company",
    "slug": "my-company",
    "clients_count": 3,
    "created_at": "2026-04-03 10:00:00"
  }
}
```

**Error response** — `404 Not Found`:

```json
{ "error": "Organization not found" }
```

---

### POST /config/test

Test SMTP connection and authentication without saving anything. Useful for validating credentials before registering a client.

**Auth:** Master key (`X-Api-Key: MASTER_API_KEY`)

**Request body:**

| Field       | Type   | Required | Description                  |
|-------------|--------|----------|------------------------------|
| `smtp_host` | string | yes      | SMTP server hostname         |
| `smtp_port` | int    | yes      | SMTP server port (465 or 587)|
| `smtp_user` | string | yes      | SMTP username                |
| `smtp_pass` | string | yes      | SMTP password                |

**Example request:**

```bash
curl -X POST http://localhost:8080/config/test \
  -H "Content-Type: application/json" \
  -H "X-Api-Key: YOUR_MASTER_KEY" \
  -d '{
    "smtp_host": "smtp.mail.ru",
    "smtp_port": 465,
    "smtp_user": "noreply@innlab.kz",
    "smtp_pass": "password123"
  }'
```

**Success response** — `200 OK`:

```json
{
  "success": true,
  "message": "SMTP connection successful"
}
```

**Failure response** — `200 OK` (not 500, because this is a test result, not a server error):

```json
{
  "success": false,
  "message": "Authentication failed: 535 5.7.8 Error: authentication failed"
}
```

---

### POST /config

Register a new client SMTP configuration under an organization. Returns a unique API key.

**Auth:** Master key (`X-Api-Key: MASTER_API_KEY`)

**Request body:**

| Field              | Type    | Required | Description                                    |
|--------------------|---------|----------|------------------------------------------------|
| `organization_id`  | int     | yes      | ID of the parent organization                  |
| `smtp_host`        | string  | yes      | SMTP server hostname                           |
| `smtp_port`        | int     | yes      | SMTP server port (465 or 587)                  |
| `smtp_user`        | string  | yes      | SMTP username                                  |
| `smtp_pass`        | string  | yes      | SMTP password (stored encrypted)               |
| `from_address`     | string  | yes      | Sender email address                           |
| `test_before_save` | boolean | no       | If `true`, test SMTP before saving (default: false) |

**Example request:**

```bash
curl -X POST http://localhost:8080/config \
  -H "Content-Type: application/json" \
  -H "X-Api-Key: YOUR_MASTER_KEY" \
  -d '{
    "organization_id": 1,
    "smtp_host": "smtp.gmail.com",
    "smtp_port": 587,
    "smtp_user": "you@gmail.com",
    "smtp_pass": "your-app-password",
    "from_address": "you@gmail.com",
    "test_before_save": true
  }'
```

**Success response** — `201 Created`:

```json
{
  "api_key": "a1b2c3d4e5f6...64-char-hex-string",
  "message": "Client registered successfully"
}
```

**Error responses:**

`400` — SMTP test failed (only when `test_before_save: true`):

```json
{
  "error": "SMTP connection test failed",
  "details": "Authentication failed for smtp.gmail.com:587"
}
```

`400` — missing fields:

```json
{ "error": "Missing required fields: organization_id, smtp_host" }
```

`404` — organization not found:

```json
{ "error": "Organization not found" }
```

---

### POST /send

Send an email using the authenticated client's stored SMTP configuration.

**Auth:** Client key (`X-Api-Key: <client-key>`)

Takes either `route` or `chatId`. With `route`, the bot is inferred from the
route unless the same name exists on more than one bot, in which case name the
bot with `botId` or `botName` and the request returns `409` until you do.

**Request body:**

| Field      | Type              | Required | Description                                        |
|------------|-------------------|----------|----------------------------------------------------|
| `to`       | string or string[]| yes      | Recipient(s) email address(es)                     |
| `subject`  | string            | no       | Email subject (default: `(no subject)`)            |
| `body`     | string            | no       | Email body                                         |
| `cc`       | string[]          | no       | CC recipients                                      |
| `bcc`      | string[]          | no       | BCC recipients                                     |
| `replyTo`  | string            | no       | Reply-To address                                   |
| `from`     | string            | no       | Override sender (default: client's `from_address`) |
| `isHtml`   | boolean           | no       | Force HTML mode (default: auto-detect by `<tags>`) |
| `priority` | string            | no       | `"high"`, `"normal"`, or `"low"`                   |
| `headers`  | object            | no       | Custom email headers (e.g. `{"X-Tag": "promo"}`)  |

**Minimal request:**

```bash
curl -X POST http://localhost:8080/send \
  -H "Content-Type: application/json" \
  -H "X-Api-Key: a1b2c3d4e5f6..." \
  -d '{
    "to": "recipient@example.com",
    "subject": "Hello",
    "body": "Plain text email"
  }'
```

**Extended request:**

```bash
curl -X POST http://localhost:8080/send \
  -H "Content-Type: application/json" \
  -H "X-Api-Key: a1b2c3d4e5f6..." \
  -d '{
    "to": ["user1@example.com", "user2@example.com"],
    "cc": ["manager@example.com"],
    "bcc": ["archive@example.com"],
    "replyTo": "support@example.com",
    "subject": "Monthly Report",
    "body": "<h1>Report</h1><p>See details below.</p>",
    "priority": "high",
    "headers": {"X-Campaign": "march-2026"}
  }'
```

**Success response** — `200 OK`:

```json
{ "message": "Email sent successfully" }
```

**Error responses:**

`400` — missing `to`:

```json
{ "error": "Missing required field: to" }
```

`500` — SMTP failure:

```json
{
  "error": "Failed to send email",
  "details": "Connection refused - connect(2) for smtp.example.com:587"
}
```

---

### GET /logs

Retrieve the send history for the authenticated client's organization. Returns the most recent 100 entries across all clients in the organization.

**Auth:** Client key (`X-Api-Key: <client-key>`)

**Example request:**

```bash
curl http://localhost:8080/logs \
  -H "X-Api-Key: a1b2c3d4e5f6..."
```

**Success response** — `200 OK`:

```json
{
  "organization": {
    "id": 1,
    "name": "My Company"
  },
  "logs": [
    {
      "id": 12,
      "to_address": ["user1@example.com", "user2@example.com"],
      "cc": ["manager@example.com"],
      "reply_to": "support@example.com",
      "priority": "high",
      "subject": "Monthly Report",
      "status": "sent",
      "error": null,
      "created_at": "2026-04-03 14:22:01"
    },
    {
      "id": 11,
      "to_address": ["bad-address@nowhere.invalid"],
      "subject": "Test",
      "status": "failed",
      "error": "Connection refused",
      "created_at": "2026-04-03 14:20:55"
    }
  ]
}
```

---

## Admin console API

These endpoints back the web console at `/ui/`. Every one of them requires the
**master key** (`X-Api-Key: <MASTER_API_KEY>`). They exist so an operator can see
and manage what the client-scoped endpoints cannot.

> **They return client API keys in plaintext.** `GET /admin/clients` includes
> `apiKey` for each client, because the console uses it to call `/send` and
> `/telegram/*` on the operator's behalf. Treat the master key accordingly.

### GET /admin/stats

```json
{
  "organizations": 3,
  "clients": 5,
  "mail":     { "total": 470, "sent": 438, "failed": 32, "last24h": 61 },
  "telegram": { "bots": 3, "enabled_bots": 2, "messages": 128 }
}
```

### GET /admin/organizations

Like `GET /organizations`, plus `clientsCount` and `logsCount` per row.

### PATCH /admin/organizations/:id

Body: `{ "name": "...", "slug": "..." }` — both optional, at least one required.
Slug must match `[a-z0-9-]+` and stay unique. Returns the updated organization.

### DELETE /admin/organizations/:id

Cascades to the organization's clients and their mail logs. `{"message": "Organization deleted"}`.

### GET /admin/clients[?organization_id=1]

```json
{
  "clients": [{
    "id": 1, "organizationId": 1, "organizationName": "Acme",
    "apiKey": "a1b2…", "smtpHost": "smtp.example.com", "smtpPort": 587,
    "smtpUser": "no-reply@example.com", "fromAddress": "no-reply@example.com",
    "logsCount": 380, "botsCount": 2, "createdAt": "2026-02-11 09:20:00"
  }]
}
```

`smtp_pass` is never returned.

### GET /admin/clients/:id

Single client, same shape.

### PATCH /admin/clients/:id

Body may carry any of `smtp_host`, `smtp_port`, `smtp_user`, `smtp_pass`,
`from_address`. Omitting `smtp_pass` leaves the stored password untouched;
supplying it re-encrypts the new value.

### POST /admin/clients/:id/rotate-key

Issues a fresh `SecureRandom.hex(32)` key. **The previous key stops working immediately.**

```json
{ "api_key": "new-key…", "message": "API key rotated — the previous key no longer works" }
```

### POST /admin/clients/:id/test

Decrypts the stored SMTP password and runs the same connect+auth check as
`/config/test`. Returns `{ "success": true|false, "message": "…" }`.

### DELETE /admin/clients/:id

Removes the client, its mail logs and its Telegram bots.

### GET /admin/logs

Query parameters — all optional: `organization_id`, `client_id`,
`status` (`sent`|`failed`), `q` (matches subject or recipient),
`limit` (1–500, default 100), `offset`.

```json
{
  "logs": [{
    "id": 1000, "clientId": 1, "organizationId": 1, "organizationName": "Acme",
    "fromAddress": "no-reply@acme.com", "toAddress": ["user@example.com"],
    "cc": [], "bcc": [], "replyTo": null, "priority": null,
    "subject": "Password reset", "status": "sent", "error": null,
    "createdAt": "2026-08-31 10:44:00"
  }],
  "total": 470, "limit": 100, "offset": 0
}
```

## Error Codes Summary

| HTTP Code | Meaning                                    |
|-----------|--------------------------------------------|
| 200       | Success                                    |
| 201       | Resource created successfully              |
| 400       | Validation error (missing required fields) |
| 401       | Missing `X-Api-Key` header                 |
| 403       | Invalid API key                            |
| 404       | Resource not found                         |
| 409       | Conflict (duplicate slug)                  |
| 500       | Server / SMTP error                        |

---

## Data Model

```
organizations 1──┐
                  │
                  ├──N clients 1──N mail_logs
                  │
organizations 1──┘
```

Each organization can have multiple clients (SMTP configs). Each client generates its own API key. Logs from `/logs` are scoped to the entire organization, so any client's API key within the org will return all logs for that org.

---

## Notes

- The `body` field in `/send` supports HTML. A plain-text version is auto-generated by stripping HTML tags.
- Port 465 uses implicit SSL; port 587 uses STARTTLS.
- SMTP passwords are encrypted with AES-256-CBC (OpenSSL) before being stored in the database and decrypted only at send time.
- Each `/send` call is logged regardless of outcome — check `/logs` to audit delivery status.
- The `/logs` endpoint returns logs for all clients within the same organization, not just the authenticating client.

---

## Telegram

The Telegram gateway lets a client register one or more Telegram bots and use them to send/receive messages and dispatch slash-commands to client-owned handler URLs. All `/telegram/*` endpoints require a **client key**.

### Model

- `client_telegram_bots` — one row per bot (token AES-256-CBC encrypted, identified by `name` like `main`/`alerts`).
- `telegram_chats` — chats authorized for a bot.
- `telegram_commands` — commands the bot exposes via `setMyCommands`. Each command has an optional `handlerUrl` (POSTed when a Telegram user invokes the command) and `handlerSecret` (sent as `X-Handler-Secret`).
- `telegram_messages` — inbound/outbound audit log.
- `telegram_bot_state` — per-bot `last_update_id` so listeners resume cleanly after restart.

A long-poll listener runs in-process (one Ruby thread per enabled bot). Restart the process and listeners resume from `last_update_id`.

### Bot resolution

For endpoints that act on a bot (`/telegram/messages`, `/telegram/chats`, `/telegram/commands`), resolution order is:

1. `botId` (numeric, scoped to your client) →
2. `botName` (string) →
3. the bot flagged `is_default = true` for your client.

### POST /telegram/bots/test

Validate a bot token via `getMe` without saving.

```json
{ "botToken": "123:abc" }
```

Response:

```json
{ "success": true, "username": "my_bot", "botId": 123456789 }
```

### POST /telegram/bots

Register a new bot. Token is validated via `getMe`, encrypted, and the listener thread is started.

```json
{ "name": "main", "botToken": "123:abc", "isDefault": true }
```

`201 Created` — returns `{ "bot": { ...full bot fields without token... } }`.

Errors: `400` (validation), `409` (`name` already exists for this client).

### GET /telegram/bots / GET /telegram/bots/:id

List or fetch your bots. Tokens are never returned.

### PATCH /telegram/bots/:id

Any subset of `{ name, isEnabled, isDefault, botToken }`. If `botToken` changes, it's revalidated via `getMe`; the listener is restarted. If `isEnabled` flips, the listener is started/stopped accordingly.

### DELETE /telegram/bots/:id

Stops the listener and cascade-deletes chats/commands/messages for this bot.

### POST /telegram/bots/:id/webhook

Switch this bot to webhook delivery. Generates a fresh secret token, calls
Telegram's `setWebhook`, records the mode, and stops the bot's polling thread.

**Auth:** Client key

```json
{ "baseUrl": "https://email.innlab.kz", "dropPendingUpdates": false }
```

`baseUrl` is optional; it defaults to `PUBLIC_BASE_URL`, then to the request's
own origin. It must be https — Telegram refuses anything else. The webhook path
is appended automatically, so the registered URL is
`<baseUrl>/telegram/webhook/<bot id>`.

Returns the updated bot plus `webhookUrl`. The secret token is never returned:
it exists only to authenticate Telegram's deliveries, and a new one is issued on
every switch.

### GET /telegram/bots/:id/webhook

What Telegram has registered, straight from `getWebhookInfo`, next to our own
`deliveryMode`. Use it when a bot goes quiet: `pendingUpdateCount` climbing and a
`lastErrorMessage` mean Telegram cannot reach the endpoint.

### DELETE /telegram/bots/:id/webhook

Back to long polling: `deleteWebhook` at Telegram, mode reset, listener started.
If Telegram rejects `deleteWebhook` the local state still moves, otherwise the
bot would be left with neither transport running.

### POST /telegram/webhook/:bot_id

**Called by Telegram, not by you.** No `X-Api-Key` — Telegram cannot send one.
The request authenticates with the `X-Telegram-Bot-Api-Secret-Token` header,
compared in constant time against the secret issued when the webhook was
registered.

Answers `200` for everything it accepts, including updates it ignores and
updates whose processing failed, because a non-2xx makes Telegram redeliver.
A wrong or missing secret token gets `403`; an unknown bot, or one with no
webhook registered, gets `404` — the same answer, so the endpoint cannot be used
to enumerate bot ids.

### POST /telegram/bots/:id/sync-commands

Force a `setMyCommands` call to Telegram. Usually unnecessary — `POST/PATCH/DELETE /telegram/commands` does this automatically.

### Routes — sending without a chat id

A **route** is a name that stands for a chat: `errors` reaches one group,
`reports` another. A calling project sends the name; which group is behind it is
decided here.

That matters because the alternative is every project hard-coding chat ids. When
a group is recreated or a notification has to move, you edit one row here instead
of redeploying each caller.

Name a route when you register the chat, or attach one later:

```bash
curl -X POST https://email.innlab.kz/telegram/chats \
  -H "X-Api-Key: <client-key>" -H "Content-Type: application/json" \
  -d '{"chatId": -1001234567890, "title": "Acme errors", "chatType": "supergroup", "routeName": "errors"}'
```

Then callers never mention a chat id again:

```bash
curl -X POST https://email.innlab.kz/telegram/messages \
  -H "X-Api-Key: <client-key>" -H "Content-Type: application/json" \
  -d '{"route": "errors", "text": "NullPointerException in OrderService"}'
```

Route names are lowercased on the way in, so `Errors` and `errors` are the same
route and a caller cannot miss by capitalisation. A name is unique per bot;
claiming one that is taken returns `409` naming the chat that holds it.

To repoint a route at a different group, clear it from the old chat and set it on
the new one with `PATCH /telegram/chats/:id`. Callers need no change.

### GET /telegram/routes

The address book: every named route for this client, with the chat and bot behind
it. Useful as the thing you hand to whoever integrates a project.

```json
{
  "routes": [
    { "route": "errors", "chatId": -1001234567890, "title": "Acme errors",
      "chatType": "supergroup", "botId": 11, "botName": "acme-support" }
  ]
}
```

### PATCH /telegram/chats/:id

Body: `title` and/or `routeName`. An empty `routeName` removes the route, leaving
the chat registered. `409` if another chat on the same bot already holds the name.

### POST /telegram/messages

Send a message. `botId` or `botName` optional (default bot used otherwise).

```json
{
  "botName": "main",
  "chatId": 217860003,
  "text": "Channel X failed",
  "parseMode": "Markdown",
  "replyToMessageId": null,
  "disableNotification": false
}
```

Response:

```json
{ "id": 42, "telegramMessageId": 555, "status": "sent" }
```

Failures are logged to `telegram_messages` with `status: "failed"` and return `500`.

### GET /telegram/messages

Filter via query params: `botId`, `chatId`, `direction` (`inbound`|`outbound`), `limit` (max 500, default 100), `offset`.

### GET /telegram/messages/:id

Single message (scoped to your client).

### POST /telegram/chats

Authorize a chat for a bot. `botId` or `botName` optional.

```json
{ "botName": "main", "chatId": 217860003, "chatType": "private", "title": "DM with admin" }
```

`chatType` ∈ `private | group | supergroup | channel`. Returns `201` for new, `200` for already-existing pair.

### GET /telegram/chats

`?botId=...` to filter, otherwise all chats across your client's bots.

### DELETE /telegram/chats/:id

Delete by row PK (not Telegram chat_id).

### POST /telegram/commands

Register a command. `botId` or `botName` optional.

```json
{
  "botName": "main",
  "command": "status",
  "description": "Show recorder status",
  "handlerUrl": "https://recorder.example.com/telegram/handlers/status",
  "handlerSecret": "deadbeef..."
}
```

`command` must match `[a-z0-9_]{1,32}` (no leading slash). Auto-syncs the bot's menu via `setMyCommands`. Returns `201`.

### Handler protocol

When a Telegram user sends `/status all`, the listener POSTs to `handlerUrl`:

```json
{
  "chatId": 217860003,
  "userId": 17,
  "username": "alice",
  "command": "status",
  "args": "all",
  "messageId": 42,
  "botId": 1,
  "botName": "main"
}
```

With header `X-Handler-Secret: <handlerSecret>` (omitted if no secret). Timeout `TELEGRAM_HANDLER_TIMEOUT_SECONDS` (default 10s).

The handler should respond JSON:

```json
{ "text": "Recorder: OK", "parseMode": "Markdown" }
```

The text is sent back to the chat as a reply to the original message. Empty or missing `text` → no reply sent.

### GET /telegram/commands

`?botId=...` to filter.

### PATCH /telegram/commands/:id

Any subset of `{ description, handlerUrl, handlerSecret, isEnabled }`. Re-syncs the menu.

### DELETE /telegram/commands/:id

Removes the command + re-syncs the menu.

### Operational notes

- Listeners are in-process threads. Production must support background threads outside of request handling: Puma OK; on Passenger set `passenger_min_instances ≥ 1` so a worker stays alive.
- Two clients can register the same bot token. Telegram only delivers `getUpdates` to one poller at a time — the other listener will receive HTTP `409 Conflict`, store `last_error`, sleep 60s, retry. This is a Telegram protocol constraint, not a gateway bug.
- Cross-client isolation: every query is scoped by `client_id` (derived from `X-Api-Key`). Client A cannot read/mutate client B's bots, chats, commands, or messages.
