# Mail Service — API Documentation

Base URL: `http://localhost:8080`

All requests and responses use `Content-Type: application/json`.

---

## Authentication

All authenticated endpoints use the `X-Api-Key` header. There are two key types:

| Key type       | Header value            | Protects                              |
|----------------|-------------------------|---------------------------------------|
| **Master key** | `MASTER_API_KEY` from `.env` | `POST /organizations`, `POST /config`, everything under `/admin` |
| **Client key** | Returned by `POST /config`  | `POST /send`, `GET /logs`, everything under `/telegram` |

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

Address fields (`to`, `cc`, `bcc`, `replyTo`, `from`) take bare addresses
only — `user@example.com`, not `Name <user@example.com>` — and at most 100
recipients in total. `headers` may carry `X-*` headers plus `List-Unsubscribe`,
`List-Unsubscribe-Post`, `List-Id`, `Precedence`, `Auto-Submitted`,
`Organization`, `Comments`, `Keywords` and `Importance`; the headers that
address or structure the message (`To`, `Bcc`, `From`, `Content-Type`,
`Message-ID`, …) come from the typed fields and are refused here with a `400`.
Line breaks inside any header value are replaced with spaces.

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

### POST /send — attachments, idempotency and delivery status

Everything in this section is additive. A call without `attachments` and
without an idempotency key is accepted exactly as before, and every field the
response used to carry is still there; the response only gains fields.

#### Attachments

**Additional request fields:**

| Field            | Type     | Required | Description                                                          |
|------------------|----------|----------|----------------------------------------------------------------------|
| `attachments`    | object[] | no       | Files to attach. Absent, `null` or `[]` means none                   |
| `idempotencyKey` | string   | no       | Fallback for the `Idempotency-Key` header (see below)                |

Each attachment:

| Field           | Type   | Required | Description                                                            |
|-----------------|--------|----------|------------------------------------------------------------------------|
| `filename`      | string | yes      | UTF-8, Cyrillic is fine. Sanitized (see below)                         |
| `contentType`   | string | yes      | Must be in the allowlist. Default allowlist: `application/pdf` only    |
| `contentBase64` | string | yes      | Standard base64 (RFC 4648), padded, **no line breaks**                 |

```bash
curl -X POST http://localhost:8080/send \
  -H "Content-Type: application/json" \
  -H "X-Api-Key: a1b2c3d4e5f6..." \
  -H "Idempotency-Key: req-1042-offer-v3" \
  -d '{
    "to": "client@example.com",
    "subject": "Коммерческое предложение REQ-1042",
    "body": "Направляем согласованное предложение.",
    "attachments": [
      { "filename": "КП_REQ-1042_v3.pdf", "contentType": "application/pdf", "contentBase64": "JVBERi0xLjcK..." }
    ]
  }'
```

Validation, in order — the first failure answers, and nothing is sent or
recorded:

| Check                                                     | Status | `field`                          |
|-----------------------------------------------------------|--------|----------------------------------|
| Request body larger than `MAIL_MAX_REQUEST_BYTES`          | `413`  | —                                |
| `attachments` is not an array                             | `400`  | `attachments`                    |
| More than `MAIL_ATTACHMENTS_MAX_COUNT` items              | `413`  | `attachments`                    |
| Item is not an object                                     | `400`  | `attachments[i]`                 |
| `filename` missing, blank, or empty after sanitizing      | `400`  | `attachments[i].filename`        |
| `contentType` missing                                     | `400`  | `attachments[i].contentType`     |
| `contentType` not in `MAIL_ATTACHMENT_ALLOWED_TYPES`      | `415`  | `attachments[i].contentType`     |
| `contentBase64` missing, empty or not strict base64       | `400`  | `attachments[i].contentBase64`   |
| Decoded file over `MAIL_ATTACHMENT_MAX_BYTES`             | `413`  | `attachments[i].contentBase64`   |
| All decoded files together over `MAIL_ATTACHMENTS_MAX_TOTAL_BYTES` | `413` | `attachments[i].contentBase64` |
| `application/pdf` whose bytes do not start with `%PDF-`   | `400`  | `attachments[i].contentBase64`   |

```json
{
  "error": "Invalid attachment",
  "details": "attachments[0].contentType 'image/png' is not allowed (allowed: application/pdf)",
  "field": "attachments[0].contentType"
}
```

Filename sanitizing keeps UTF-8 letters and the extension; it removes control
and format characters (CR/LF, NUL, bidi overrides), replaces `/ \ < > : " | ? *`
with `_`, collapses whitespace, strips leading dots, and cuts the name to 180
characters.

The message is `multipart/mixed`: the body first (`text/plain`, or a
`multipart/alternative` of text and HTML), then each attachment,
base64-encoded. Non-ASCII filenames are written twice, the way the `mail` gem
does it — RFC 2231 in `Content-Type: …; name*=utf-8''…` and an RFC 2047 encoded
word in `Content-Disposition: attachment; filename="=?UTF-8?B?…?="` — so both
old and new mail clients show the Cyrillic name.

Attachment content is never logged or stored. `mail_logs` and
`mail_send_attempts` keep only `{filename, contentType, size, sha256}`.

#### Idempotency-Key

Send `Idempotency-Key: <key>` (1–255 printable ASCII characters, no spaces).
The body field `idempotencyKey` is accepted for callers that cannot set
headers; the header wins, and giving both with different values is a `400`.
Keys are scoped to the client (API key's client row), so two clients never
collide.

| Situation (same client, same key, within `MAIL_IDEMPOTENCY_TTL_HOURS`) | Result |
|-----------------------------------------------------|----------------------------------------------------------------------|
| First request                                       | Sent normally; the outcome is stored against the key                 |
| Repeat, same payload, first one finished            | **Not sent again.** The stored outcome is returned with the original HTTP status, `"idempotentReplay": true` and header `Idempotent-Replayed: true` |
| Repeat, same payload, first one still sending       | `409` `{ "error": "...still in progress", "status": "in_progress", "attemptId": "..." }` |
| Repeat, **different** payload                       | `422` `{ "error": "Idempotency-Key was already used with a different request", "attemptId": "..." }` |
| Attempt store unreachable                           | `503`, nothing sent                                                  |

"Same payload" is a SHA-256 over the normalized request (recipients, sender,
subject, body, flags, headers and each attachment's filename, content type,
size and SHA-256). A replay of a `failed` attempt is still `failed` — to try
again after a definite failure, use a new key. After the retention window the
key is released and may be reused; the old attempt stays readable through
`GET /send/:attemptId`.

Validation errors (`400`/`413`/`415`) do not consume the key.

#### Response fields

| Field              | When                    | Meaning                                                            |
|--------------------|-------------------------|--------------------------------------------------------------------|
| `message`          | `sent`                  | `"Email sent successfully"` — unchanged                            |
| `error`, `details` | `failed`, `unknown`     | As before; `details` is the SMTP/network error                     |
| `status`           | always                  | `sent` \| `failed` \| `unknown` (`in_progress` only on `409`)      |
| `attemptId`        | when recorded           | UUID of this attempt, for `GET /send/:attemptId`                   |
| `messageId`        | always                  | The `Message-ID` header value (without `<>`) — known even when the outcome is unknown |
| `smtpResponse`     | `sent`, when available  | The server's final reply to DATA, e.g. `250 2.0.0 Ok: queued as ABC123` |
| `idempotencyKey`   | when a key was given    | The key                                                            |
| `attachments`      | when there were any     | `[{ filename, contentType, size, sha256 }]` as sent (sanitized name) |
| `idempotentReplay` | on a replay             | `true`                                                             |

| `status`  | HTTP  | Meaning                                                                    | Retry? |
|-----------|-------|----------------------------------------------------------------------------|--------|
| `sent`    | `200` | The SMTP server accepted the message (250 after DATA)                      | —      |
| `failed`  | `500` | Definitely not accepted: connection/auth/recipient failure, or an SMTP error reply to DATA | Yes, with a **new** key |
| `unknown` | `504` | The body was transmitted but the final reply never arrived (timeout, connection drop) — the message may or may not have been queued | **No automatic retry.** Check `GET /send/:attemptId`, the recipient's mailbox (by `messageId`), or ask a human |

```json
{
  "message": "Email sent successfully",
  "status": "sent",
  "attemptId": "3f0c9a52-5f0e-4d8e-9d0c-2b8c7a0e4f11",
  "messageId": "3f0c9a52-5f0e-4d8e-9d0c-2b8c7a0e4f11@altyn.kz",
  "smtpResponse": "250 2.0.0 Ok: queued as 4ZK1c2",
  "idempotencyKey": "req-1042-offer-v3",
  "attachments": [
    { "filename": "КП_REQ-1042_v3.pdf", "contentType": "application/pdf", "size": 182344,
      "sha256": "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08" }
  ]
}
```

```json
{
  "error": "Delivery outcome unknown, do not retry automatically",
  "details": "Net::ReadTimeout",
  "status": "unknown",
  "attemptId": "3f0c9a52-5f0e-4d8e-9d0c-2b8c7a0e4f11",
  "messageId": "3f0c9a52-5f0e-4d8e-9d0c-2b8c7a0e4f11@altyn.kz"
}
```

The service itself never retries a send. `unknown` is also written to
`mail_logs.status` (and is a filter value in `GET /admin/logs`).

#### GET /send/:attemptId

**Auth:** Client key. Only the client that made the attempt can read it; any
other key, a malformed id, or an unknown id is `404`.

```json
{
  "attemptId": "3f0c9a52-5f0e-4d8e-9d0c-2b8c7a0e4f11",
  "status": "sent",
  "messageId": "3f0c9a52-5f0e-4d8e-9d0c-2b8c7a0e4f11@altyn.kz",
  "smtpResponse": "250 2.0.0 Ok: queued as 4ZK1c2",
  "idempotencyKey": "req-1042-offer-v3",
  "attachments": [ { "filename": "КП_REQ-1042_v3.pdf", "contentType": "application/pdf", "size": 182344, "sha256": "…" } ],
  "createdAt": "2026-09-30 12:00:00 +0500",
  "completedAt": "2026-09-30 12:00:02 +0500"
}
```

`status` may also be `in_progress` (still sending — or the process died
mid-send, in which case it stays so; treat a long-lived `in_progress` like
`unknown`), `failed` (with `error`) or `unknown`. Fields without a value are
omitted.

`GET /logs` entries gain `attemptId` and `attachments` (metadata) when present.

#### Configuration

| ENV variable                        | Default                     | Meaning                                                   |
|-------------------------------------|-----------------------------|-----------------------------------------------------------|
| `MAIL_ATTACHMENTS_MAX_COUNT`        | `5`                         | Max attachments per message                               |
| `MAIL_ATTACHMENT_MAX_BYTES`         | `10485760` (10 MiB)         | Max decoded size of one attachment                        |
| `MAIL_ATTACHMENTS_MAX_TOTAL_BYTES`  | `20971520` (20 MiB)         | Max decoded size of all attachments together              |
| `MAIL_ATTACHMENT_ALLOWED_TYPES`     | `application/pdf`           | Comma-separated MIME allowlist. `%PDF-` is checked for PDF |
| `MAIL_MAX_REQUEST_BYTES`            | base64 of the total + 1 MiB (≈ 27 MiB) | Max `Content-Length` of `POST /send`           |
| `MAIL_IDEMPOTENCY_TTL_HOURS`        | `24`                        | How long a key stays bound to its first attempt           |
| `MAIL_SMTP_OPEN_TIMEOUT_SECONDS`    | `10`                        | SMTP connect timeout                                      |
| `MAIL_SMTP_READ_TIMEOUT_SECONDS`    | `60`                        | SMTP reply timeout (was the `mail` gem's 5 s)             |

Rack, Sinatra and Puma impose no body limit of their own. A reverse proxy in
front of the app does: nginx defaults to `client_max_body_size 1m`, which
rejects any real PDF with a `413` before the app sees it. Raise it (and
Apache's `LimitRequestBody`, if set) to at least `MAIL_MAX_REQUEST_BYTES` on
the host.

Storage: migration `008_mail_send_attempts.sql` adds the `mail_send_attempts`
table (unique `(client_id, idempotency_key)` — the insert of the `in_progress`
row is the claim on a key, so concurrent duplicates cannot both send) and adds
`attempt_id`, `attachments` and the `unknown` status to `mail_logs`.

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

### GET /admin/telegram/grants

Which organizations have been lent which bot, across every client. Optional
filters: `?botId=` and `?organizationId=`.

```json
{
  "grants": [
    { "id": 1, "botId": 11, "botName": "acme-support", "botUsername": "acme_support_bot",
      "ownerOrganizationName": "Acme Corporation",
      "organizationId": 2, "organizationName": "Globex", "organizationSlug": "globex",
      "createdAt": "2026-09-08 11:00:00" }
  ]
}
```

### POST /admin/telegram/grants

```json
{ "botId": 11, "organizationId": 2 }
```

`organizationSlug` works in place of `organizationId`. Same rules and same
errors as the owner-key form — see
[Sharing a bot](#sharing-a-bot-with-another-organization).

### DELETE /admin/telegram/grants/:id

Revokes one grant by its own id.

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
| 409       | Conflict (duplicate slug, route name, or grant) |
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

The Telegram tables hang off `clients`, but their **security boundary is the organization**, the same as `/logs`:

```
clients 1──N client_telegram_bots 1──N telegram_chats
                                  1──N telegram_commands
                                  1──N telegram_messages
                                  1──1 telegram_bot_state
                                  1──N telegram_bot_grants N──1 organizations
```

A bot is reachable by the organization of the client that connected it, plus every organization in `telegram_bot_grants`. Chats, commands and messages are then filtered by the bots you can reach — never by the client that happened to create them.

---

## Notes

- The `body` field in `/send` supports HTML. A plain-text version is auto-generated by stripping HTML tags.
- Port 465 uses implicit SSL; port 587 uses STARTTLS.
- SMTP passwords are encrypted with AES-256-CBC (OpenSSL) before being stored in the database and decrypted only at send time.
- Each `/send` call is logged regardless of outcome — check `/logs` to audit delivery status.
- The `/logs` endpoint returns logs for all clients within the same organization, not just the authenticating client.
- The same holds for `/telegram/*`: a bot is visible to its owning organization and to any organization granted it, not to one client alone.

---

## Telegram

The Telegram gateway lets a client register one or more Telegram bots and use them to send/receive messages and dispatch slash-commands to client-owned handler URLs. All `/telegram/*` endpoints require a **client key**.

A bot is owned by the **organization** of the client that connected it — every client in that organization can administer it. It can additionally be **granted** to other organizations, which then get everything except the bot itself. See [Sharing a bot](#sharing-a-bot-with-another-organization).

### Model

- `client_telegram_bots` — one row per bot (token AES-256-CBC encrypted, identified by `name` like `main`/`alerts`).
- `telegram_chats` — chats authorized for a bot.
- `telegram_commands` — commands the bot exposes via `setMyCommands`. Each command has an optional `handlerUrl` (POSTed when a Telegram user invokes the command) and `handlerSecret` (sent as `X-Handler-Secret`).
- `telegram_messages` — inbound/outbound audit log.
- `telegram_bot_state` — per-bot `last_update_id` so listeners resume cleanly after restart.
- `telegram_bot_grants` — organizations this bot has been lent to (see [Sharing a bot](#sharing-a-bot-with-another-organization)).

A long-poll listener runs in-process (one Ruby thread per enabled bot). Restart the process and listeners resume from `last_update_id`.

### Bot resolution

For endpoints that act on a bot (`/telegram/messages`, `/telegram/chats`, `/telegram/commands`), resolution order is:

1. `botId` (numeric) →
2. `botName` (string) →
3. the bot flagged `is_default = true`.

Each step searches every bot you can reach — your organization's own, plus any granted to it. A `botName` is unique per client but not across grants, so when two reachable bots answer to the same name your organization's own wins.

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

List or fetch your bots. Tokens are never returned. Each bot object:

```json
{
  "id": 11,
  "name": "main",
  "botUsername": "acme_support_bot",
  "botId": 123456789,
  "isEnabled": true,
  "deliveryMode": "webhook",
  "webhookUrl": "https://email.innlab.kz/telegram/webhook/11",
  "messageHandlerUrl": "https://your-project.example/telegram/message",
  "hasMessageHandlerSecret": true,
  "isDefault": true,
  "lastError": null,
  "lastSeen": "2026-09-07 12:03:11",
  "createdAt": "2026-09-01 10:00:00",
  "updatedAt": "2026-09-04 18:22:41",
  "ownerOrganizationId": 1,
  "ownerOrganizationName": "Acme Corporation",
  "isOwner": true,
  "grants": []
}
```

`deliveryMode` is `polling` or `webhook`. Secrets (bot token, message handler
secret, webhook secret) are never returned — only the boolean saying one is set.

### PATCH /telegram/bots/:id

Any subset of `{ name, isEnabled, isDefault, botToken, messageHandlerUrl, messageHandlerSecret }`. If `botToken` changes, it's revalidated via `getMe`; the listener is restarted. If `isEnabled` flips, the listener is started/stopped accordingly. `messageHandlerUrl` is where non-command messages go — see [Inbound messages that are not commands](#inbound-messages-that-are-not-commands); an empty string clears it.

Handler URLs (`messageHandlerUrl` here, `handlerUrl` on commands) are places
this service will POST to on your behalf, so they are checked when saved and
again before every call: `http` or `https`, a public host, the scheme's default
port or a port ≥ 1024, no credentials in the URL. `localhost`, private ranges
(`10/8`, `172.16/12`, `192.168/16`), loopback, link-local (`169.254/16`) and
their IPv6 equivalents are refused with a `400` naming the field.

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

### Sharing a bot with another organization

One bot, several organizations. The owner keeps the bot; the grantee gets to
use it.

A grant hands the other organization everything hanging off the bot — it
registers its own chats and routes, edits commands, reads the bot's message
history, and sends. It does **not** get the bot row itself: the token, the
delivery mode and deleting the bot stay with the owner, because a token and a
webhook are one-per-bot globals at Telegram and two organizations cannot both
hold them.

What a grant does not do is partition the bot. Everyone holding one sees the
bot's whole traffic and can send to every route on it, because it is one
Telegram identity. Grant a bot to an organization you would let post in every
chat it already reaches; where that is not true, register a second bot with
@BotFather instead.

Owner-side endpoints take the **owner's client key**. A bot the caller merely
borrows answers `404` here, not `403` — the same answer as a bot that does not
exist, so the endpoint cannot be used to enumerate other organizations' bots.

#### GET /telegram/bots/:id/grants

```json
{
  "grants": [
    { "id": 1, "botId": 11, "organizationId": 2, "organizationName": "Globex",
      "organizationSlug": "globex", "createdAt": "2026-09-08 11:00:00" }
  ]
}
```

#### POST /telegram/bots/:id/grants

Name the organization by id or by slug:

```bash
curl -X POST https://email.innlab.kz/telegram/bots/11/grants \
  -H "X-Api-Key: <owner-client-key>" -H "Content-Type: application/json" \
  -d '{"organizationSlug": "globex"}'
```

`201` with the grant. Errors: `400` (that organization already owns the bot),
`404` (no such bot, or no such organization), `409` (it already has access).

#### DELETE /telegram/bots/:id/grants/:grant_id

Revokes it. The grantee's chats, routes and commands on the bot stay in the
database; they simply stop being reachable, so re-granting restores them.

#### Master-key equivalents

The same table across every client, for an operator who is not holding the
owner's key: `GET /admin/telegram/grants` (optional `?botId=` / `?organizationId=`),
`POST /admin/telegram/grants` with `{botId, organizationId}`, and
`DELETE /admin/telegram/grants/:id`.

#### What the grantee sees

`GET /telegram/bots` returns owned and granted bots together. Tell them apart
with `isOwner`; `ownerOrganizationName` says who lent it:

```json
{
  "id": 11, "name": "acme-support", "isOwner": false,
  "ownerOrganizationId": 1, "ownerOrganizationName": "Acme Corporation"
}
```

For an owner the same call adds `grants`, the list above, so the console can
render access without a second request per bot.

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

Send a message. Address the chat with either `route` (preferred — see
[Routes](#routes--sending-without-a-chat-id)) or a raw `chatId`. `botId` /
`botName` are optional; the default bot is used otherwise.

```json
{
  "route": "errors",
  "text": "Channel X failed",
  "parseMode": "Markdown",
  "replyToMessageId": null,
  "disableNotification": false
}
```

The raw-id form, when the caller genuinely holds a chat id:

```json
{
  "botName": "main",
  "chatId": 217860003,
  "text": "Channel X failed"
}
```

Response:

```json
{ "id": 42, "telegramMessageId": 555, "status": "sent" }
```

Errors: `400` (missing `text`, or neither `route` nor `chatId`), `404`
(unknown route), `409` (the route name exists on more than one of your bots —
add `botId` or `botName` to disambiguate). Send failures are logged to
`telegram_messages` with `status: "failed"` and return `500`.

### GET /telegram/messages

Inbound and outbound traffic for every bot you can reach — the ones your organization owns and the ones granted to it. An owner therefore sees a grantee's sends on their bot, and a grantee sees the bot's inbound messages; the `clientId` on each row still records who sent it.

Filter via query params: `botId`, `chatId`, `direction` (`inbound`|`outbound`), `limit` (max 500, default 100), `offset`. A `botId` you cannot reach narrows the result to nothing rather than widening it.

### GET /telegram/messages/:id

Single message, scoped the same way.

### POST /telegram/chats

Authorize a chat for a bot. `botId` or `botName` optional.

```json
{ "botName": "main", "chatId": 217860003, "chatType": "private", "title": "DM with admin" }
```

`chatType` ∈ `private | group | supergroup | channel`. Returns `201` for new, `200` for already-existing pair.

### GET /telegram/chats

`?botId=...` to filter, otherwise all chats across every bot you can reach — owned and granted alike.

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

### Inbound messages that are not commands

A command reaches the `handler_url` on its own `telegram_commands` row. Anything
else — ordinary text, and slash commands with no row — reaches the bot's
**message handler**, if one is set:

```bash
curl -X PATCH https://email.innlab.kz/telegram/bots/11 \
  -H "X-Api-Key: <client-key>" -H "Content-Type: application/json" \
  -d '{"messageHandlerUrl": "https://your-project.example/telegram/message",
       "messageHandlerSecret": "<shared secret>"}'
```

Without one, a plain message is written to `telegram_messages` and goes no
further: it is visible in the console and invisible to your project. Send
`messageHandlerUrl: ""` to go back to that.

The payload and the reply are the same shape as a command's, so one endpoint can
serve both. `command` is `null` for ordinary text, and carries the name for a
slash command nothing claimed — which is how you tell a question from a typo:

```json
{
  "chatId": -1001234567890,
  "chatType": "supergroup",
  "userId": 55512345,
  "username": "bekzat",
  "text": "where is my order?",
  "command": null,
  "args": null,
  "messageId": 901,
  "botId": 11,
  "botName": "acme-support"
}
```

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

`?botId=...` to filter, otherwise all commands across every bot you can reach.

### PATCH /telegram/commands/:id

Any subset of `{ description, handlerUrl, handlerSecret, isEnabled }`. Re-syncs the menu.

### DELETE /telegram/commands/:id

Removes the command + re-syncs the menu.

### Operational notes

- Listeners are in-process threads. Production must support background threads outside of request handling: Puma OK; on Passenger set `passenger_min_instances ≥ 1` so a worker stays alive.
- Two clients can register the same bot token. Telegram only delivers `getUpdates` to one poller at a time — the other listener will receive HTTP `409 Conflict`, store `last_error`, sleep 60s, retry, and on webhook the second `setWebhook` silently overwrites the first. This is a Telegram protocol constraint, not a gateway bug. It is also why [a grant](#sharing-a-bot-with-another-organization) is the supported way to share a bot: one registration, one transport, many organizations.
- Isolation is per **organization**: every query resolves the bots the caller's organization owns or has been granted, and filters chats, commands and messages by those. An organization with no share of a bot cannot read or mutate anything on it.
- Owner-only, on every bot: `PATCH`/`DELETE /telegram/bots/:id`, the three webhook endpoints, and the grant endpoints. Everything else a grantee can do.
