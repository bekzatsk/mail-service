ALTER TABLE mail_logs
    MODIFY to_address TEXT NOT NULL COMMENT 'JSON array of recipients',
    ADD COLUMN cc TEXT NULL COMMENT 'JSON array of CC recipients' AFTER to_address,
    ADD COLUMN bcc TEXT NULL COMMENT 'JSON array of BCC recipients' AFTER cc,
    ADD COLUMN reply_to VARCHAR(255) NULL AFTER bcc,
    ADD COLUMN priority VARCHAR(10) NULL AFTER reply_to;
