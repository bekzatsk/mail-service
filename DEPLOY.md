# Deployment on cPanel (Passenger)

## Prerequisites

- cPanel hosting with SSH access
- Ruby support (via "Setup Ruby App" in cPanel or rbenv)
- MySQL database (create via cPanel → MySQL Databases)

## Step-by-step

### 1. Upload files to server

```bash
# Via SSH
cd ~
git clone <repo-url> mail-service

# Or upload via cPanel File Manager to /home/username/mail-service
```

### 2. Run the setup script

```bash
cd ~/mail-service
bash setup.sh
```

This will install gems, create `.env`, and configure `.htaccess` with correct paths.

### 3. Create MySQL database via cPanel

Go to **cPanel → MySQL Databases**:

1. Create database: `mail_service` (cPanel will prefix it, e.g., `username_mail_service`)
2. Create user with a password
3. Add user to database with **ALL PRIVILEGES**

### 4. Configure .env

```bash
nano .env
```

```
DB_HOST=localhost
DB_PORT=3306
DB_NAME=username_mail_service
DB_USER=username_dbuser
DB_PASS=your-db-password

ENCRYPTION_KEY=<run: ruby -e "require 'securerandom'; puts SecureRandom.hex(32)">
MASTER_API_KEY=<run: ruby -e "require 'securerandom'; puts SecureRandom.hex(32)">
```

### 5. Setup Ruby App in cPanel

Go to **cPanel → Setup Ruby App**:

1. Click **Create Application**
2. Ruby version: **3.x** (latest available)
3. App mode: **Production**
4. Application root: `mail-service`
5. Application URL: choose your domain/subdomain (e.g., `api.yourdomain.com`)
6. Application startup file: `config.ru`
7. Click **Create**

After creation, cPanel will show a command to enter the virtual environment. Run it:

```bash
source /home/username/nodevenv/... # cPanel shows the exact path
cd ~/mail-service
bundle install
```

### 6. Restart the app

```bash
# Create tmp dir if not exists
mkdir -p ~/mail-service/tmp

# Restart Passenger
touch ~/mail-service/tmp/restart.txt
```

### 7. Point domain/subdomain

If using a subdomain like `api.yourdomain.com`:

1. Go to **cPanel → Subdomains**
2. Create subdomain `api`
3. Set document root to `/home/username/mail-service`
4. Or use **cPanel → Setup Ruby App** to map the URL

### 8. Verify

```bash
# Test the API
curl https://api.yourdomain.com/organizations

# Create first organization (use your MASTER_API_KEY)
curl -X POST https://api.yourdomain.com/organizations \
  -H "Content-Type: application/json" \
  -H "X-Api-Key: YOUR_MASTER_KEY" \
  -d '{ "name": "My Company" }'
```

## Troubleshooting

### Check logs

```bash
# Passenger / Apache error log
tail -f ~/logs/error.log

# Or in cPanel → Errors
```

### Restart after code changes

```bash
touch ~/mail-service/tmp/restart.txt
```

### Gem installation issues

```bash
# Enter Ruby virtual environment first (cPanel shows the command)
source /home/username/...
cd ~/mail-service
bundle config set --local path 'vendor/bundle'
bundle install
touch tmp/restart.txt
```

### Database connection refused

Make sure `DB_HOST=localhost` (not `127.0.0.1`) on shared hosting — some cPanel setups require `localhost` to use Unix socket.

### Permission errors

```bash
chmod -R 755 ~/mail-service
chmod 600 ~/mail-service/.env
```
