ALTER TABLE client_telegram_bots
    ADD COLUMN message_handler_url TEXT NULL COMMENT 'Receives anything not matched by a telegram_commands row' AFTER webhook_url,
    ADD COLUMN message_handler_secret VARCHAR(255) NULL COMMENT 'Sent as X-Handler-Secret to message_handler_url' AFTER message_handler_url
