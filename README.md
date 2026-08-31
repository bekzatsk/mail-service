# Mail Service

Lightweight Ruby microservice for sending emails via per-client SMTP configurations. Clients belong to organizations — each organization can have multiple SMTP configurations (clients), and logs are scoped per organization.

## Stack

- Ruby 3.x
- Sinatra 3
- Mail gem
- MySQL (mysql2)
- Puma
- dotenv

## Project Structure

```
mail-service/
├── app.rb                              # Sinatra application (routes)
├── config.ru                           # Rack entry point (Puma / Passenger)
├── Gemfile
├── .env.example
├── db/
│   └── migrations/
│       └── 001_create_tables.sql
├── public/
│   └── ui/                             # Admin console (static, no build step)
│       ├── index.html
│       ├── css/                        # tokens · base · components · views
│       └── js/                         # api · store · router · ui · shell · views/
└── app/
    ├── handlers/
    │   ├── organization_handler.rb     # POST/GET /organizations
    │   ├── config_handler.rb           # POST /config — client registration
    │   ├── mail_handler.rb             # POST /send, GET /logs
    │   ├── telegram_handler.rb         # /telegram/*
    │   └── admin_handler.rb            # /admin/* — console backend (master key)
    ├── middleware/
    │   └── api_key_middleware.rb        # Rack middleware: auth layer
    └── services/
        ├── database.rb                 # MySQL connection (mysql2)
        ├── encryption_service.rb       # AES-256-CBC encrypt/decrypt
        └── mail_service.rb             # Mail gem wrapper + logging
```

## Admin console

The service ships with a web console at **`/ui/`** (`/` redirects there). It is
plain HTML/CSS/ES modules served straight out of `public/ui` — no Node, no build
step, nothing to compile before deploying.

Unlock it with the `MASTER_API_KEY`, then manage:

- **Organizations** — create, rename, re-slug, delete
- **Clients & keys** — issue keys, edit SMTP config, test stored credentials, rotate or revoke keys
- **Mail logs** — filter by organization, client, status or text; inspect the full envelope and delivery error
- **Telegram** — bots, slash commands, chats and message history for the selected client
- **Send test** — compose a message through any client key

The console keeps the master key in `sessionStorage` (or `localStorage` if you
tick "keep me signed in") and sends it as `X-Api-Key` on every request. Because
the master key can read every client key, only unlock it on a trusted machine
and serve the service over HTTPS.

## Requirements

- Ruby >= 3.0
- Bundler
- MySQL server
- OpenSSL (usually bundled with Ruby)

## Installation

```bash
git clone <repo-url> mail-service
cd mail-service
bundle install
```

## Configuration

Copy the example environment file and fill in your values:

```bash
cp .env.example .env
```

| Variable         | Description                                    | Example              |
|------------------|------------------------------------------------|----------------------|
| `DB_HOST`        | MySQL host                                     | `127.0.0.1`          |
| `DB_PORT`        | MySQL port                                     | `3306`                |
| `DB_NAME`        | Database name                                  | `mail_service`        |
| `DB_USER`        | Database user                                  | `root`                |
| `DB_PASS`        | Database password                              | `secret`              |
| `ENCRYPTION_KEY` | Key for AES-256 encryption of SMTP passwords   | `my-strong-key-here`  |
| `MASTER_API_KEY` | Admin key for creating organizations & clients | *(generate, see below)* |

Generate keys:

```bash
ruby -e "require 'securerandom'; puts SecureRandom.hex(32)"
```

## Database Setup

The database and all tables are created **automatically** when the app starts. The built-in migrator (`app/services/migrator.rb`) runs on every boot and will:

1. Create the database if it doesn't exist
2. Create a `schema_migrations` tracking table
3. Run any pending SQL files from `db/migrations/` in order
4. Skip already-executed migrations

Just make sure `DB_USER` has `CREATE DATABASE` privileges. No manual SQL needed.

To add new migrations later, create a new file like `db/migrations/002_add_something.sql` — it will run automatically on next startup.

## Running

**Development** (Puma):

```bash
bundle exec puma config.ru -p 8080
# or
bundle exec rackup config.ru -p 8080
```

**Production** (cPanel + Passenger): see [DEPLOY.md](DEPLOY.md) for full step-by-step guide, or quick start:

```bash
ssh user@yourhost
cd ~/mail-service
bash setup.sh       # installs gems, configures .htaccess
nano .env            # set DB credentials and keys
touch tmp/restart.txt
```

> **Background threads (Telegram listeners).** The Telegram gateway runs one long-poll thread per enabled bot inside the app process. Production must keep at least one worker alive between requests:
> - Puma — works out of the box.
> - Passenger — set `passenger_min_instances ≥ 1` and disable idle shutdown (`passenger_pool_idle_time 0` if you can), otherwise Telegram listeners die between requests. Set `TELEGRAM_ENABLED=false` to disable the gateway entirely on hosts that can't keep workers alive.

## Authentication

The service uses two types of API keys via the `X-Api-Key` header:

| Key type         | Used for                                       | How to get                  |
|------------------|------------------------------------------------|-----------------------------|
| **Master key**   | all `/organizations*`, `/config*`, `/admin/*`  | Set `MASTER_API_KEY` in `.env` |
| **Client key**   | `POST /send`, `GET /logs`, all `/telegram/*`   | Returned by `POST /config`  |

No API endpoint is public. The only unauthenticated routes are the console's own
static assets under `/ui/` (and `/`, which redirects there).

## Quick Start

1. Create an organization (master key required):

```bash
curl -X POST http://localhost:8080/organizations \
  -H "Content-Type: application/json" \
  -H "X-Api-Key: YOUR_MASTER_KEY" \
  -d '{ "name": "My Company" }'
```

2. Register a client SMTP config (master key required):

```bash
curl -X POST http://localhost:8080/config \
  -H "Content-Type: application/json" \
  -H "X-Api-Key: YOUR_MASTER_KEY" \
  -d '{
    "organization_id": 1,
    "smtp_host": "smtp.gmail.com",
    "smtp_port": 587,
    "smtp_user": "you@gmail.com",
    "smtp_pass": "app-password",
    "from_address": "you@gmail.com"
  }'
```

Response: `{ "api_key": "abc123...", "message": "Client registered successfully" }`

3. Send an email (client key):

```bash
curl -X POST http://localhost:8080/send \
  -H "Content-Type: application/json" \
  -H "X-Api-Key: abc123..." \
  -d '{
    "to": "recipient@example.com",
    "subject": "Hello",
    "body": "<h1>Hi there!</h1>"
  }'
```

4. View send logs (client key, scoped to organization):

```bash
curl http://localhost:8080/logs -H "X-Api-Key: abc123..."
```

For full API documentation see [API_README.md](API_README.md).

## CI/CD

The pipeline lives in [`.flux-ci.yml`](.flux-ci.yml) and runs on [Flux CI](https://flux.innlab.kz/docs/pipeline). Flux imports that file from the repository on first open, on "Sync from repo", and on any push that touches it.

| Stage | Job | What it proves |
|-------|-----|----------------|
| verify | `ruby-syntax` | every `.rb` and `config.ru` parses |
| verify | `console-modules` | every console ES module parses; no `innerHTML`/`eval`; every asset `index.html` references exists |
| verify | `secret-scan` | no `.env`, credential assignment, live API key or private key in the tracked tree |
| test | `route-auth` | 69 assertions on who may reach which route with which key |
| test | `console-smoke` | the console boots in Chromium, every view renders, no uncaught errors, no overflow at 320–1920px |
| deploy | `deploy-ftps` | **manual** — FTPS mirror to the host, then verifies the live service |

Run any of them locally — none needs a database:

```bash
ruby test/middleware_routes_test.rb
sh script/check-ui-modules.sh
sh script/check-secrets.sh

npm i --no-save playwright@1.62.1 && npx playwright install chromium
node test/ui_smoke_test.mjs
```

`node test/support/mock_api.mjs 8117` serves the console against fixtures at <http://127.0.0.1:8117/ui/> (master key `test-master-key`) — useful for working on the UI without a database.

### Deploy

`deploy-ftps` is `when: manual`, so a push builds and tests without shipping anything; someone presses play to deploy.

It mirrors the repository to the Plesk host over FTPS and then uploads `tmp/restart.txt` to make Passenger reload. Set in Flux:

| Name | Kind | Notes |
|------|------|-------|
| `FLUX_FTP_USER` | org secret | the shared FTP account for this host — already defined org-wide |
| `FLUX_FTP_PASS` | org secret | reaches every domain on the shared host, so keep it protected |
| `MAIL_SITE_URL` | variable (secret overrides) | `https://email.innlab.kz` — the deploy refuses to run without it |
| `FLUX_FTP_HOST` | org secret | `.flux-ci.yml` carries a fallback, but the secret wins |
| `MAIL_REMOTE_DIR` | variable | `email.innlab.kz` — the FTP directory is the domain itself, no `httpdocs` level |

Every one of these is guarded at the top of the deploy job. A protected secret arrives as an empty string on a non-protected ref *and still overrides the fallback in the file*, so an empty value is a real possibility for any of them, not just the credentials.

The FTP credentials are the host-wide `FLUX_FTP_*` pair rather than anything named for this service, because one account covers every domain on the Plesk host. A protected secret arrives as an empty string on a non-protected ref, so `FLUX_FTP_USER is empty` from the deploy job means either "not defined" or "this ref is not protected".

Two consequences of deploying over FTPS worth knowing:

- **Gems are not shipped.** There is no `bundle install` at the far end. After a `Gemfile` change, run it on the host once.
- **Nothing is deleted.** The mirror never passes `--delete`, because the host holds `.env`, `vendor/bundle` and `tmp/`, which are not in this repo. A file removed from the repo stays on the server until removed by hand.

Before uploading a byte it checks that `MAIL_REMOTE_DIR` exists and holds a `config.ru`, so a wrong directory fails immediately instead of creating one nobody serves.

The job finishes by checking the live service: `/organizations` must answer `401` (the app restarted and auth is enforced) and `/ui/` must serve the console. Either failing fails the deploy.

## Security

- SMTP passwords are encrypted with AES-256-CBC before storage. The IV is generated per-record and stored alongside the ciphertext.
- API keys are 64-character hex strings generated via `SecureRandom.hex(32)`.
- The `ENCRYPTION_KEY` environment variable is hashed with SHA-256 to derive the actual 32-byte encryption key.
- Master key comparison uses constant-time algorithm to prevent timing attacks.
- Never commit your `.env` file to version control.
- `GET /admin/clients` returns client API keys in plaintext — the console needs them to act on a client's behalf. Anyone holding the master key already has full control, but keep the console behind HTTPS and off shared machines.

## License

MIT
