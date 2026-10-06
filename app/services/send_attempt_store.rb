# frozen_string_literal: true

require 'json'
require 'securerandom'
require_relative 'database'

module Services
  # Persistence for POST /send attempts (migration 008): one row per send,
  # keyed publicly by a UUID `attempt_id`, optionally claimed by a client's
  # Idempotency-Key.
  #
  # The unique index (client_id, idempotency_key) is what makes "never send
  # twice" hold across concurrent requests and workers: the INSERT of the
  # in_progress row is the claim, and a duplicate-key error means someone else
  # already holds it.
  #
  # Only attachment metadata is stored — never content.
  class SendAttemptStore
    STATUSES = %w[in_progress sent failed unknown].freeze
    DEFAULT_TTL_HOURS = 24
    MYSQL_DUPLICATE_ENTRY = 1062
    MAX_ERROR_CHARS = 1000
    MAX_RESPONSE_CHARS = 500

    COLUMNS = 'attempt_id, client_id, idempotency_key, request_hash, status, message_id, ' \
              'smtp_response, error, attachments, created_at, completed_at'

    attr_reader :ttl_hours

    def initialize(ttl_hours: nil, database: Database)
      @ttl_hours = ttl_hours || positive_int(ENV['MAIL_IDEMPOTENCY_TTL_HOURS'], DEFAULT_TTL_HOURS)
      @db = database
    end

    # Records a new attempt as in_progress.
    #
    # With an idempotency key, the row is also the claim on that key. If the
    # key is already held (within the retention window), nothing is inserted
    # and the existing row is returned instead.
    #
    # @return [Hash] { created: true, attempt_id: } or { created: false, attempt: row }
    def begin_attempt(client_id:, request_hash:, attachments: [], idempotency_key: nil)
      release_expired_key(client_id, idempotency_key) if idempotency_key

      attempt_id = SecureRandom.uuid
      @db.query(
        'INSERT INTO mail_send_attempts (attempt_id, client_id, idempotency_key, request_hash, status, attachments)
         VALUES (?, ?, ?, ?, ?, ?)',
        [attempt_id, client_id, idempotency_key, request_hash, 'in_progress', encode_attachments(attachments)]
      )
      { created: true, attempt_id: attempt_id }
    rescue StandardError => e
      raise unless idempotency_key && duplicate_entry?(e)

      existing = find_by_key(client_id, idempotency_key)
      raise unless existing

      { created: false, attempt: existing }
    end

    # Stores the final outcome. Only an in_progress row can be completed, so a
    # stored result is never overwritten.
    def finish_attempt(attempt_id, status:, message_id: nil, smtp_response: nil, error: nil)
      raise ArgumentError, "unknown status #{status}" unless STATUSES.include?(status) && status != 'in_progress'

      @db.query(
        "UPDATE mail_send_attempts
         SET status = ?, message_id = ?, smtp_response = ?, error = ?, completed_at = CURRENT_TIMESTAMP
         WHERE attempt_id = ? AND status = 'in_progress'",
        [status, message_id, truncate(smtp_response, MAX_RESPONSE_CHARS), truncate(error, MAX_ERROR_CHARS), attempt_id]
      )
    end

    # An attempt as seen by the client that made it. Other clients get nil.
    def find(client_id, attempt_id)
      first(@db.query(
        "SELECT #{COLUMNS} FROM mail_send_attempts WHERE attempt_id = ? AND client_id = ?",
        [attempt_id, client_id]
      ))
    end

    def find_by_key(client_id, idempotency_key)
      first(@db.query(
        "SELECT #{COLUMNS} FROM mail_send_attempts WHERE client_id = ? AND idempotency_key = ?",
        [client_id, idempotency_key]
      ))
    end

    # Decodes the stored attachments JSON (metadata only).
    def self.attachments_of(row)
      raw = row && row['attachments']
      return [] if raw.nil? || raw.empty?

      JSON.parse(raw)
    rescue JSON::ParserError
      []
    end

    private

    # After the retention window a key is free again. The old row is kept (so
    # GET /send/:attemptId still answers) — only its claim on the key goes.
    def release_expired_key(client_id, idempotency_key)
      @db.query(
        'UPDATE mail_send_attempts SET idempotency_key = NULL
         WHERE client_id = ? AND idempotency_key = ? AND created_at < (CURRENT_TIMESTAMP - INTERVAL ? HOUR)',
        [client_id, idempotency_key, ttl_hours]
      )
    end

    def duplicate_entry?(error)
      (error.respond_to?(:error_number) && error.error_number == MYSQL_DUPLICATE_ENTRY) ||
        error.message.to_s.include?('Duplicate entry')
    end

    def encode_attachments(attachments)
      list = Array(attachments).map { |a| a.respond_to?(:metadata) ? a.metadata : a }
      list.empty? ? nil : JSON.generate(list)
    end

    def first(result)
      result&.first
    end

    def truncate(value, limit)
      return nil if value.nil?

      text = value.to_s
      text.length > limit ? text[0, limit] : text
    end

    def positive_int(raw, default)
      value = Integer(raw.to_s.strip, 10)
      value.positive? ? value : default
    rescue ArgumentError, TypeError
      default
    end
  end
end
