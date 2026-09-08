CREATE TABLE IF NOT EXISTS telegram_bot_grants (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    bot_id BIGINT NOT NULL,
    organization_id INT NOT NULL COMMENT 'Organization the bot is shared with',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    UNIQUE KEY uniq_bot_grant_org (bot_id, organization_id),
    FOREIGN KEY (bot_id) REFERENCES client_telegram_bots(id) ON DELETE CASCADE,
    FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
