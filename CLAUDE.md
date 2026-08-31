# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
bundle install                              # install gems
bundle exec puma config.ru -p 8080          # run dev server
bundle exec rackup config.ru -p 8080        # alternative dev server
touch tmp/restart.txt                       # restart under Passenger (prod)
bash setup.sh                               # cPanel/Passenger first-time setup

# Checks — these are exactly what CI runs, and all four run without a database
ruby test/middleware_routes_test.rb         # route/key authorization matrix
sh script/check-ui-modules.sh               # console modules parse, no unsafe sinks
sh script/check-secrets.sh                  # no credential in the tracked tree
node test/ui_smoke_test.mjs                 # console in a browser (needs playwright)

node test/support/mock_api.mjs 8117          # console against fixtures, no DB
```

No linter configured. Migrations run automatically on boot — never invoke them manually.

The smoke test needs Playwright, which is not vendored: `npm i --no-save playwright@1.62.1 && npx playwright install chromium`. `node_modules/` is gitignored.

## Architecture

Sinatra + Rack microservice. Single entry point `config.ru` loads `.env`, runs `Services::Migrator.new.run!`, mounts `Middleware::ApiKeyMiddleware`, then `run App` (Sinatra app in `app.rb`).

### Request lifecycle

1. `ApiKeyMiddleware` (`app/middleware/api_key_middleware.rb`) classifies the route:
   - `PUBLIC_PATHS` / `PUBLIC_ROUTES` — GET `/`, GET `/ui*`, GET `/favicon*` pass through. These are the console's static assets only; **no API endpoint is public**.
   - `MASTER_ROUTES` (exact) — POST `/organizations`, `/config`, `/config/test`; `MASTER_PREFIXES` — everything under `/admin` plus GET `/organizations*`. Both require `X-Api-Key == MASTER_API_KEY` (constant-time compare). A *client* key on these routes gets 403, not a fallthrough.
   - Anything else requires a client API key; the matching `clients` row + joined `organizations` data is injected as `env['mail_service.client']`.
2. `App` (Sinatra) routes delegate to handler instances. Each handler method returns a Rack triple `[status, headers, [body]]`; the `emit` helper unpacks it onto the Sinatra response. Keep this triple shape when adding handlers.
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
- `public/ui/` — the admin console. Static ES modules, no build step (see "Admin console" below).

### Data model

`organizations 1—N clients 1—N mail_logs`. The org is the security boundary for `/logs`: any client key in an org sees all logs across all clients in that org (see `MailHandler#logs` join). `mail_logs.to_address`, `cc`, `bcc` are JSON-encoded arrays stored as TEXT — read via `parse_json_field`.

Telegram tables (migration 003) hang off `clients`, not `organizations`: `clients 1—N client_telegram_bots 1—N {telegram_chats, telegram_commands, telegram_messages}`, plus `telegram_bot_state` (1:1 with bot, stores `last_update_id` for resume). `client_telegram_bots.bot_token` is AES-256-CBC encrypted via the same `EncryptionService` as `clients.smtp_pass`. Cross-client isolation for `/telegram/*` is per-client (not per-org) — every query filters by `client['id']` from `X-Api-Key`.

### Telegram subsystem

Two transports, chosen per bot by `client_telegram_bots.delivery_mode` (`polling` | `webhook`, migration 004):

- **webhook** — Telegram POSTs to `/telegram/webhook/:bot_id`. That route is in `PUBLIC_ROUTES` because Telegram cannot send our `X-Api-Key`; what authenticates it is `X-Telegram-Bot-Api-Secret-Token`, compared against the per-bot `webhook_secret` with `Services::SecureCompare`. No threads, so it survives Passenger suspending an idle process and cannot duplicate across workers. This is the mode production wants.
- **polling** — `TelegramBotListener` in a thread, as before. The supervisor only starts threads for bots whose `delivery_mode` is `polling`; running both against one bot earns a 409 from Telegram, which is exactly the failure this split avoids.

`Services::TelegramUpdateProcessor` holds everything that happens *to* an update — log it, match a command, POST to `handler_url`, reply. Both transports call it, so they cannot drift. The transport decides only how an update arrives.

The webhook endpoint answers 200 for anything it accepts, including updates it ignores and updates whose processing raised: a non-2xx makes Telegram redeliver, so a persistent bug would become a retry storm.

- `Services::TelegramService` — thin Net::HTTP wrapper over `https://api.telegram.org/bot<TOKEN>/<method>`. Raises `ApiError` / `ConflictError` (409); never stores state.
- `Services::TelegramBotListener` — one instance per bot, runs `getUpdates` long-poll loop in its own thread. Reads token via `EncryptionService.decrypt`, persists `last_update_id` to `telegram_bot_state` after each update, writes `last_seen` / `last_error` to `client_telegram_bots`. Slash-commands: matched against `telegram_commands`, POSTed to `handler_url` with `X-Handler-Secret`, reply JSON `{text, parseMode}` is sent back to the chat.
- `Services::TelegramBotSupervisor` — singleton thread manager (`instance.boot!` / `start(bot_id)` / `stop(bot_id)` / `restart(bot_id)` / `shutdown!`). `boot!` runs from `config.ru` after migrations; installs `at_exit` + `Signal.trap(TERM/INT)` for graceful shutdown. Handlers call `start`/`stop`/`restart` after successful DB writes.
- Outbound sends address a **route** or a raw `chatId`. A route is `telegram_chats.route_name` (migration 005), unique per bot, lowercased on write so callers cannot miss by capitalisation. It exists so a calling project never stores a chat id: repointing `errors` at a different group is a row change here, not a deploy there. `send_message` resolves the route across the client's bots first and only falls back to `resolve_bot`; a name present on two bots is a 409 rather than a guess.

`Services::TelegramCommandSync.sync!(bot_id)` — pushes current `is_enabled = TRUE` commands for a bot via `setMyCommands` (or `deleteMyCommands` if empty). Called automatically by command POST/PATCH/DELETE; failures are warned, not raised.

Listeners are in-process threads — a bot left on `polling` needs the worker kept alive (Puma OK; Passenger needs `passenger_min_instances ≥ 1`). Webhook bots have no such requirement, which is why they are the answer on Plesk/Passenger. Kill switch: `TELEGRAM_ENABLED=false` skips supervisor boot entirely and does not affect webhook bots.

Registering a webhook needs `PUBLIC_BASE_URL` (https). Without it the handler falls back to `request.base_url`, which is a guess behind a proxy.

### Admin console

`/ui/` serves a single-page operator console from `public/ui` (Sinatra static, `set :public_folder` → `public`; `GET /` redirects to `/ui/`). Sinatra's `static!` runs before the `before` filter, so the global `content_type :json` never touches the assets — but the explicit `get '/ui'` route must pass `type: :html` to `send_file` for that reason.

- Plain ES modules loaded via `<script type="module">`. **No build step, no Node** — this is deliberate, the production target is shared cPanel hosting.
- Routing is hash-based (`#/clients`), so deep links survive a reload without a server rewrite.
- `public/ui/js/ui.js` builds DOM through `el()` and only ever assigns `textContent`. Never introduce `innerHTML` there — API strings flow straight into these nodes.
- `public/ui/js/store.js` owns state as a frozen object plus subscribers; `refresh()` reloads orgs, clients and stats together.
- Two credential scopes exist in `api.js`: `admin(masterKey)` for `/admin/*`, and `client(apiKey)` for `/send` and `/telegram/*`. The console gets client keys from `GET /admin/clients` and uses the one picked in the header "Scope" switcher.
- Nav highlight and breadcrumb call `parseHash()` directly rather than `currentRoute()`; their `hashchange` listeners are registered before the router's, so the cached route would otherwise lag one navigation behind.

`Handlers::AdminHandler` (`app/handlers/admin_handler.rb`) backs it: stats, organization update/delete, client list/show/update/delete, key rotation, stored-credential SMTP test, and filtered mail logs. It adds no tables — no migration was needed.

### CI/CD

`.flux-ci.yml` drives [Flux CI](https://flux.innlab.kz/docs/pipeline) — GitLab-shaped syntax, but a small subset of it. Keys Flux does not implement (`before_script`, `rules`, `only`, `extends`, `cache`, `services`, `retry`) parse fine and do nothing, so a config written from GitLab habits saves cleanly and silently misbehaves.

Three stages: **verify** (`ruby-syntax`, `console-modules`, `secret-scan`), **test** (`route-auth`, `console-smoke`), **deploy** (`deploy-ftps`, `when: manual`).

Things about this pipeline that are load-bearing:

- **No `changes:` anywhere.** A skipped job skips everything that `needs` it, and `deploy-ftps` needs all three checks — path-filtering any of them would silently skip the deploy instead of the check.
- **All lines of a job run in one shell** with `set -e`. `cd` persists between lines; each line is not its own step.
- **Never put an lftp invocation in a folded (`>`) block.** YAML folding joins equally-indented lines with a space but *keeps the newlines of more-indented lines*, and a newline inside `lftp -e "..."` separates commands. A `mirror` whose option lines were more-indented ran as a bare `mirror --reverse`, which defaults to the current directory on both sides and uploaded the whole workspace — `.git` included — into the FTP account root. Both lftp calls are single physical lines, the mirror `cd`s first and names source and target explicitly, and `test/ci_config_test.rb` asserts all of that, and runs as the `pipeline-config` job.
- **A YAML plain scalar cannot contain `": "` or start with `": "`.** `echo "NOTE: ..."` must be single-quoted or the save fails with a parse error pointing at that line.
- **`find -exec ruby -c` exits 0 even when a file fails to parse**, which would take `ruby-syntax` green on a syntax error. It loops with `|| exit 1` instead.
- **The deploy never passes `--delete`.** The host holds `.env`, `vendor/bundle` and `tmp/`, none of which are in this repo; a pruning mirror would take the service down. It also means a file deleted from the repo is not deleted from the host.
- **Gems are not shipped.** FTPS cannot run `bundle install`; a Gemfile change needs a manual bundle on the host.
- The deploy gates on the live service — `/organizations` must answer 401 and `/ui/` must serve the console — because a mirror that uploaded fine but left the old process running is still a failed deploy.

The deploy target is the directory `mail.innlab.kz` on the shared host — that is where the checkout lives (`config.ru`, `.env`, `vendor/`, `tmp/`). The service answers on `https://email.innlab.kz`, an alias onto the same document root, so the directory name and the site URL differ on purpose. The document root is the application root itself, not `public/`, which is why the Plesk welcome `index.html` still wins at `/` and the console is reached at `/ui/` through Sinatra's static handler.

Credentials are the host-wide org secrets `FLUX_FTP_USER` / `FLUX_FTP_PASS` — one FTP account covers every domain on the Plesk host, so there is no mail-service-specific pair. Plain variables in the file: `FLUX_FTP_HOST`, `MAIL_REMOTE_DIR`, `MAIL_SITE_URL` (must be set somewhere; the deploy refuses without it). A protected secret is an empty string on a non-protected ref, so "is empty" from a guard means either undefined or withheld from this ref.

### API key conventions

- Master key: env var, compared constant-time, used for admin endpoints.
- Client key: `SecureRandom.hex(32)`, stored plaintext in `clients.api_key` (the column has `UNIQUE` index — middleware does a single indexed lookup). `GET /admin/clients` returns it; that is intentional, the console needs it to reach the client-scoped endpoints.
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
