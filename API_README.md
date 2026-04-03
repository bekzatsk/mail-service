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

`GET /organizations` and `GET /organizations/:id` are public — no key required.

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

**Auth:** None (public endpoint)

**Example request:**

```bash
curl http://localhost:8080/organizations
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

**Auth:** None (public endpoint)

**Example request:**

```bash
curl http://localhost:8080/organizations/1
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
