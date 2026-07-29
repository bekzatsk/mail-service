# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
bundle install                              # install gems
bundle exec puma config.ru -p 8080          # run dev server
bundle exec rackup config.ru -p 8080        # alternative dev server
touch tmp/restart.txt                       # restart under Passenger (prod)
bash setup.sh                               # cPanel/Passenger first-time setup
```

No test suite exists. No linter configured. Migrations run automatically on boot — never invoke them manually.

## Architecture

Sinatra + Rack microservice. Single entry point `config.ru` loads `.env`, runs `Services::Migrator.new.run!`, mounts `Middleware::ApiKeyMiddleware`, then `run App` (Sinatra app in `app.rb`).

### Request lifecycle

1. `ApiKeyMiddleware` (`app/middleware/api_key_middleware.rb`) classifies the route:
   - `PUBLIC_ROUTES` — GET `/organizations*` pass through.
   - `MASTER_ROUTES` — POST `/organizations`, `/config`, `/config/test` require `X-Api-Key == MASTER_API_KEY` (constant-time compare).
   - Anything else requires a client API key; the matching `clients` row + joined `organizations` data is injected as `env['mail_service.client']`.
2. `App` (Sinatra) routes delegate to handler instances. Each handler method returns a Rack triple `[status, headers, [body]]`; Sinatra routes unpack and re-emit it. Keep this triple shape when adding handlers.
3. Handlers call `Services::*` for DB, encryption, SMTP test, and mail delivery.

### Layers

- `app/handlers/` — HTTP shape (JSON parse, validation, status codes). One handler class per resource. Do not put DB or SMTP logic here.
- `app/services/` — Business logic and side effects:
  - `Database` — singleton `Mysql2::Client` with `query(sql, params)` using prepared statements. Always use this; never instantiate `Mysql2::Client` ad-hoc except in `Migrator` (which needs to connect before the DB exists).
  - `EncryptionService` — AES-256-CBC for `clients.smtp_pass`. Key derived from `ENV['ENCRYPTION_KEY']` via SHA-256. IV is random per-encrypt and prepended to the ciphertext before base64. Decrypt only happens at send time in `MailService`.
  - `MailService` — wraps the `mail` gem. Port 465 → implicit SSL; otherwise STARTTLS. Auto-detects HTML by regex unless `is_html` is set; HTML mode also generates a stripped plaintext part. Always logs to `mail_logs` (sent or failed) — log failure is swallowed with `warn`, never raised.
  - `SmtpTestService` — `Net::SMTP` connect+auth with a 10s timeout, returns `{success:, message:}`. Used both by `/config/test` and by `/config` when `test_before_save: true`.
  - `Migrator` — runs every boot. Creates DB if missing, tracks executed files in `schema_migrations`, splits each SQL file on `;` and executes statements one-by-one. **Consequence: never use `;` inside a single statement (no stored procs, no triggers with bodies).** Add a new file `db/migrations/NNN_*.sql` and it runs on next start.
- `app/middleware/` — Rack middleware only.

### Data model

`organizations 1—N clients 1—N mail_logs`. The org is the security boundary for `/logs`: any client key in an org sees all logs across all clients in that org (see `MailHandler#logs` join). `mail_logs.to_address`, `cc`, `bcc` are JSON-encoded arrays stored as TEXT — read via `parse_json_field`.

Telegram tables (migration 003) hang off `clients`, not `organizations`: `clients 1—N client_telegram_bots 1—N {telegram_chats, telegram_commands, telegram_messages}`, plus `telegram_bot_state` (1:1 with bot, stores `last_update_id` for resume). `client_telegram_bots.bot_token` is AES-256-CBC encrypted via the same `EncryptionService` as `clients.smtp_pass`. Cross-client isolation for `/telegram/*` is per-client (not per-org) — every query filters by `client['id']` from `X-Api-Key`.

### Telegram subsystem

- `Services::TelegramService` — thin Net::HTTP wrapper over `https://api.telegram.org/bot<TOKEN>/<method>`. Raises `ApiError` / `ConflictError` (409); never stores state.
- `Services::TelegramBotListener` — one instance per bot, runs `getUpdates` long-poll loop in its own thread. Reads token via `EncryptionService.decrypt`, persists `last_update_id` to `telegram_bot_state` after each update, writes `last_seen` / `last_error` to `client_telegram_bots`. Slash-commands: matched against `telegram_commands`, POSTed to `handler_url` with `X-Handler-Secret`, reply JSON `{text, parseMode}` is sent back to the chat.
- `Services::TelegramBotSupervisor` — singleton thread manager (`instance.boot!` / `start(bot_id)` / `stop(bot_id)` / `restart(bot_id)` / `shutdown!`). `boot!` runs from `config.ru` after migrations; installs `at_exit` + `Signal.trap(TERM/INT)` for graceful shutdown. Handlers call `start`/`stop`/`restart` after successful DB writes.
- `Services::TelegramCommandSync.sync!(bot_id)` — pushes current `is_enabled = TRUE` commands for a bot via `setMyCommands` (or `deleteMyCommands` if empty). Called automatically by command POST/PATCH/DELETE; failures are warned, not raised.

Listeners are in-process threads — production deploys must keep workers alive (Puma OK; Passenger needs `passenger_min_instances ≥ 1`). Kill switch: `TELEGRAM_ENABLED=false` skips supervisor boot entirely.

### API key conventions

- Master key: env var, compared constant-time, used for admin endpoints.
- Client key: `SecureRandom.hex(32)`, stored plaintext in `clients.api_key` (the column has `UNIQUE` index — middleware does a single indexed lookup).
- Header is always `X-Api-Key`. Missing → 401, invalid → 403.

## Conventions

- Frozen string literals at the top of every Ruby file.
- JSON request bodies parsed via a private `parse_json(request)` helper that rewinds the body and returns `{}` on parse error.
- JSON response helper returns a Rack triple: `[status, {'Content-Type' => 'application/json'}, [JSON.generate(payload)]]`.
- Request field names are camelCase on the wire (`replyTo`, `isHtml`) and converted to snake_case Ruby keys inside the handler.
- Errors as `{error: '...'}` plus details `{details: '...'}` when there's a downstream message worth forwarding.

## Environment

Required env vars (loaded from `.env` via dotenv): `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASS`, `ENCRYPTION_KEY`, `MASTER_API_KEY`. `ENCRYPTION_KEY` and `MASTER_API_KEY` are 64-char hex — generate with `ruby -e "require 'securerandom'; puts SecureRandom.hex(32)"`. Rotating `ENCRYPTION_KEY` invalidates every stored `smtp_pass`.

Production target is cPanel + Passenger (see `DEPLOY.md`). `.htaccess` is rewritten by `setup.sh` to point at the local Ruby. On shared hosting use `DB_HOST=localhost` (Unix socket) not `127.0.0.1`.
