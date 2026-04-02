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
└── app/
    ├── handlers/
    │   ├── organization_handler.rb     # POST/GET /organizations
    │   ├── config_handler.rb           # POST /config — client registration
    │   └── mail_handler.rb             # POST /send, GET /logs
    ├── middleware/
    │   └── api_key_middleware.rb        # Rack middleware: auth layer
    └── services/
        ├── database.rb                 # MySQL connection (mysql2)
        ├── encryption_service.rb       # AES-256-CBC encrypt/decrypt
        └── mail_service.rb             # Mail gem wrapper + logging
```

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

## Authentication

The service uses two types of API keys via the `X-Api-Key` header:

| Key type         | Used for                                 | How to get                  |
|------------------|------------------------------------------|-----------------------------|
| **Master key**   | `POST /organizations`, `POST /config`    | Set `MASTER_API_KEY` in `.env` |
| **Client key**   | `POST /send`, `GET /logs`                | Returned by `POST /config`  |

`GET /organizations` and `GET /organizations/:id` are public (no key required).

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

## Security

- SMTP passwords are encrypted with AES-256-CBC before storage. The IV is generated per-record and stored alongside the ciphertext.
- API keys are 64-character hex strings generated via `SecureRandom.hex(32)`.
- The `ENCRYPTION_KEY` environment variable is hashed with SHA-256 to derive the actual 32-byte encryption key.
- Master key comparison uses constant-time algorithm to prevent timing attacks.
- Never commit your `.env` file to version control.

## License

MIT
