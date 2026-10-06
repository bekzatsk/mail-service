CREATE TABLE IF NOT EXISTS mail_send_attempts (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    attempt_id CHAR(36) NOT NULL COMMENT 'Public UUID returned as attemptId',
    client_id INT NOT NULL,
    idempotency_key VARCHAR(255) NULL COMMENT 'Idempotency-Key header, NULL when absent or after the retention window',
    request_hash CHAR(64) NOT NULL COMMENT 'SHA-256 of the normalized request, attachments enter only by their own SHA-256',
    status ENUM('in_progress', 'sent', 'failed', 'unknown') NOT NULL DEFAULT 'in_progress',
    message_id VARCHAR(255) NULL COMMENT 'Message-ID header of the built message',
    smtp_response VARCHAR(512) NULL COMMENT 'Final SMTP reply to DATA, when accepted',
    error TEXT NULL,
    attachments TEXT NULL COMMENT 'JSON metadata only (filename, contentType, size, sha256), never content',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    completed_at TIMESTAMP NULL DEFAULT NULL,
    UNIQUE KEY uniq_mail_send_attempt_id (attempt_id),
    UNIQUE KEY uniq_mail_send_idempotency (client_id, idempotency_key),
    KEY idx_mail_send_attempts_created (created_at),
    FOREIGN KEY (client_id) REFERENCES clients(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

ALTER TABLE mail_logs
    MODIFY status ENUM('sent', 'failed', 'unknown') NOT NULL,
    ADD COLUMN attempt_id CHAR(36) NULL COMMENT 'mail_send_attempts.attempt_id' AFTER client_id,
    ADD COLUMN attachments TEXT NULL COMMENT 'JSON metadata only (filename, contentType, size, sha256), never content' AFTER priority,
    ADD KEY idx_mail_logs_attempt_id (attempt_id);
