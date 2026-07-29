CREATE TABLE IF NOT EXISTS client_telegram_bots (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    client_id INT NOT NULL,
    name VARCHAR(64) NOT NULL,
    bot_token TEXT NOT NULL COMMENT 'AES-256-CBC encrypted',
    bot_username VARCHAR(64),
    bot_id BIGINT,
    is_enabled BOOLEAN DEFAULT TRUE,
    is_default BOOLEAN DEFAULT FALSE,
    last_error TEXT,
    last_seen TIMESTAMP NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    UNIQUE KEY uniq_client_bot_name (client_id, name),
    FOREIGN KEY (client_id) REFERENCES clients(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS telegram_bot_state (
    bot_id BIGINT PRIMARY KEY,
    last_update_id BIGINT NOT NULL DEFAULT 0,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    FOREIGN KEY (bot_id) REFERENCES client_telegram_bots(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS telegram_chats (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    bot_id BIGINT NOT NULL,
    chat_id BIGINT NOT NULL,
    title VARCHAR(255),
    chat_type ENUM('private','group','supergroup','channel') NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    UNIQUE KEY uniq_bot_chat (bot_id, chat_id),
    INDEX idx_chat_id (chat_id),
    FOREIGN KEY (bot_id) REFERENCES client_telegram_bots(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS telegram_commands (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    bot_id BIGINT NOT NULL,
    command VARCHAR(32) NOT NULL,
    description VARCHAR(255) NOT NULL,
    handler_url TEXT,
    handler_secret VARCHAR(255),
    is_enabled BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    UNIQUE KEY uniq_bot_command (bot_id, command),
    FOREIGN KEY (bot_id) REFERENCES client_telegram_bots(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS telegram_messages (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    bot_id BIGINT NOT NULL,
    client_id INT NOT NULL,
    direction ENUM('outbound','inbound') NOT NULL,
    chat_id BIGINT NOT NULL,
    telegram_message_id BIGINT,
    user_id BIGINT,
    username VARCHAR(64),
    text TEXT,
    parse_mode VARCHAR(16),
    status ENUM('queued','sent','failed','received') NOT NULL,
    error_message TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_client_created (client_id, created_at),
    INDEX idx_chat_created (chat_id, created_at),
    INDEX idx_bot_created (bot_id, created_at),
    FOREIGN KEY (bot_id) REFERENCES client_telegram_bots(id) ON DELETE CASCADE,
    FOREIGN KEY (client_id) REFERENCES clients(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
