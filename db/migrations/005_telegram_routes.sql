ALTER TABLE telegram_chats
    ADD COLUMN route_name VARCHAR(64) NULL COMMENT 'Stable name a caller sends instead of a chat_id' AFTER title,
    ADD UNIQUE KEY uniq_bot_route (bot_id, route_name)
