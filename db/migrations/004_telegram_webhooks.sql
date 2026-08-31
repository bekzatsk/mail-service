ALTER TABLE client_telegram_bots
    ADD COLUMN delivery_mode ENUM('polling', 'webhook') NOT NULL DEFAULT 'polling' AFTER is_enabled,
    ADD COLUMN webhook_secret VARCHAR(255) NULL COMMENT 'X-Telegram-Bot-Api-Secret-Token expected on inbound updates' AFTER delivery_mode,
    ADD COLUMN webhook_url TEXT NULL COMMENT 'URL last registered with setWebhook' AFTER webhook_secret
