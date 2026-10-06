# frozen_string_literal: true

require 'digest'
require_relative '../services/database'
require_relative '../services/mail_service'
require_relative '../services/attachment_validator'
require_relative '../services/send_attempt_store'

module Handlers
  class MailHandler
    # Printable ASCII, no spaces — fits the unique index and any HTTP header.
    IDEMPOTENCY_KEY_FORMAT = /\A[\x21-\x7E]{1,255}\z/
    ATTEMPT_ID_FORMAT = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

    # HTTP status per stored outcome. `failed` keeps the 500 that /send has
    # always answered with; `unknown` is 504 so no client mistakes it for
    # either success or a safe-to-retry failure.
    OUTCOME_HTTP_STATUS = { 'sent' => 200, 'failed' => 500, 'unknown' => 504, 'in_progress' => 409 }.freeze

    # One address: no whitespace, no control characters, one @, a dot in the
    # domain. Not a full RFC 5322 parse — the mail gem does that — but enough
    # to keep header separators and display-name tricks out of address fields.
    ADDRESS_FORMAT = /\A[^\s@<>,;"\\[:cntrl:]]+@[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+\z/
    MAX_RECIPIENTS = 100
    MAX_SUBJECT_CHARS = 998

    # Custom headers: the caller may add X-* and a few list/tracking headers.
    # Anything that addresses, identifies or structures the message is built by
    # MailService from the typed fields and cannot be overridden from `headers`.
    HEADER_NAME_FORMAT = /\A[A-Za-z0-9][A-Za-z0-9-]{0,63}\z/
    ALLOWED_HEADER_PREFIX = 'x-'
    ALLOWED_HEADERS = %w[list-unsubscribe list-unsubscribe-post list-id precedence auto-submitted
                         organization comments keywords importance].freeze
    MAX_CUSTOM_HEADERS = 20
    MAX_HEADER_VALUE_CHARS = 998

    def initialize(mail_service: nil, attempts: nil, validator: nil)
      @mail_service = mail_service || Services::MailService.new
      @attempts     = attempts || Services::SendAttemptStore.new
      @validator    = validator || Services::AttachmentValidator.from_env
    end

    # POST /send
    # Send an email using the authenticated client's SMTP config.
    def send_mail(request, client)
      content_length = request_content_length(request)
      if content_length && content_length > max_request_bytes
        return json_response({ error: 'Request body too large',
                               details: "limit is #{max_request_bytes} bytes" }, 413)
      end

      data = parse_json(request)

      # Validate: to is required (string or array); shape is checked below.
      to = data['to']
      return json_response({ error: 'Missing required field: to' }, 400) if to.nil?

      idempotency_key, key_error = extract_idempotency_key(request, data)
      return key_error if key_error

      begin
        attachments = @validator.validate(data['attachments'])
      rescue Services::AttachmentValidator::Error => e
        return json_response({ error: 'Invalid attachment', details: e.message, field: e.field }.compact, e.status)
      end

      to_list,  to_error  = address_list(to, 'to')
      return to_error if to_error
      return json_response({ error: 'Missing required field: to' }, 400) if to_list.empty?
      cc_list,  cc_error  = address_list(data['cc'], 'cc')
      return cc_error if cc_error
      bcc_list, bcc_error = address_list(data['bcc'], 'bcc')
      return bcc_error if bcc_error
      if to_list.length + cc_list.length + bcc_list.length > MAX_RECIPIENTS
        return json_response({ error: "Too many recipients (max #{MAX_RECIPIENTS})" }, 400)
      end

      reply_to, reply_error = optional_address(data['replyTo'], 'replyTo')
      return reply_error if reply_error
      from, from_error = optional_address(data['from'], 'from')
      return from_error if from_error

      subject = data['subject'].nil? ? '(no subject)' : data['subject'].to_s
      return json_response({ error: 'subject is too long' }, 400) if subject.length > MAX_SUBJECT_CHARS

      headers, header_error = custom_headers(data['headers'])
      return header_error if header_error

      unless data['body'].nil? || data['body'].is_a?(String)
        return json_response({ error: 'body must be a string' }, 400)
      end

      params = {
        to:          to_list,
        cc:          cc_list,
        bcc:         bcc_list,
        reply_to:    reply_to,
        from:        from,
        subject:     strip_crlf(subject),
        body:        data['body'] || '',
        is_html:     data['isHtml'],
        priority:    data['priority'],
        headers:     headers,
        attachments: attachments
      }

      request_hash = request_fingerprint(params)
      claim = begin_attempt(client, idempotency_key, request_hash, attachments)
      return claim[:response] if claim[:response]

      attempt_id = claim[:attempt_id]
      result = @mail_service.send(client, params.merge(attempt_id: attempt_id))
      finish_attempt(attempt_id, result, tracked: claim[:tracked])

      outcome_response(
        status:          result[:status] || (result[:success] ? 'sent' : 'failed'),
        attempt_id:      claim[:tracked] ? attempt_id : nil,
        message_id:      result[:message_id],
        smtp_response:   result[:smtp_response],
        error:           result[:error],
        idempotency_key: idempotency_key,
        attachments:     attachments.map(&:metadata)
      )
    end

    # GET /send/:attempt_id
    # The stored outcome of one attempt, visible only to the client that made it.
    def show_attempt(client, attempt_id)
      return json_response({ error: 'Attempt not found' }, 404) unless attempt_id.to_s.match?(ATTEMPT_ID_FORMAT)

      row = @attempts.find(client['id'], attempt_id)
      return json_response({ error: 'Attempt not found' }, 404) unless row

      json_response(attempt_payload(row))
    end

    # GET /logs
    # Retrieve mail send history for the authenticated client.
    def logs(client)
      results = Services::Database.query(
        'SELECT ml.id, ml.attempt_id, ml.to_address, ml.cc, ml.bcc, ml.reply_to, ml.priority, ml.attachments, ml.subject, ml.status, ml.error, ml.created_at
         FROM mail_logs ml
         JOIN clients c ON c.id = ml.client_id
         WHERE c.organization_id = ?
         ORDER BY ml.created_at DESC LIMIT 100',
        [client['organization_id']]
      )

      logs = results.map do |row|
        entry = {
          id:         row['id'],
          to_address: parse_json_field(row['to_address']),
          subject:    row['subject'],
          status:     row['status'],
          error:      row['error'],
          created_at: row['created_at']&.to_s
        }
        entry[:cc]       = parse_json_field(row['cc']) if row['cc']
        entry[:bcc]      = parse_json_field(row['bcc']) if row['bcc']
        entry[:reply_to] = row['reply_to'] if row['reply_to']
        entry[:priority] = row['priority'] if row['priority']
        entry[:attemptId] = row['attempt_id'] if row['attempt_id']
        entry[:attachments] = parse_json_field(row['attachments']) if row['attachments']
        entry
      end

      json_response({
        organization: {
          id:   client['organization_id'],
          name: client['organization_name']
        },
        logs: logs
      })
    end

    private

    def max_request_bytes
      @max_request_bytes ||= begin
        value = Integer(ENV['MAIL_MAX_REQUEST_BYTES'].to_s.strip, 10)
        value.positive? ? value : @validator.max_request_bytes
      rescue ArgumentError, TypeError
        @validator.max_request_bytes
      end
    end

    def request_content_length(request)
      raw = request.env['CONTENT_LENGTH'] if request.respond_to?(:env)
      raw.nil? || raw.to_s.empty? ? nil : raw.to_i
    end

    # The Idempotency-Key header is primary; `idempotencyKey` in the body is
    # accepted for callers that cannot set headers. Both given and different
    # is a client bug, not something to guess about.
    def extract_idempotency_key(request, data)
      header = request.respond_to?(:env) ? request.env['HTTP_IDEMPOTENCY_KEY'] : nil
      body   = data['idempotencyKey']
      header = nil if header.is_a?(String) && header.strip.empty?
      body   = nil if body.is_a?(String) && body.strip.empty?

      if header && body && header != body
        return [nil, json_response({ error: 'Idempotency-Key header and idempotencyKey field disagree' }, 400)]
      end

      key = header || body
      return [nil, nil] if key.nil?

      unless key.is_a?(String) && key.match?(IDEMPOTENCY_KEY_FORMAT)
        return [nil, json_response({ error: 'Invalid Idempotency-Key',
                                     details: '1-255 printable ASCII characters, no spaces' }, 400)]
      end

      [key, nil]
    end

    # SHA-256 over a canonical form of everything that affects the message.
    # Attachments enter by metadata (incl. their own SHA-256), never by bytes.
    def request_fingerprint(params)
      canonical = params.merge(attachments: params[:attachments].map(&:metadata))
      Digest::SHA256.hexdigest(JSON.generate(canonicalize(canonical)))
    end

    def canonicalize(value)
      case value
      when Hash  then value.map { |k, v| [k.to_s, canonicalize(v)] }.sort_by(&:first).to_h
      when Array then value.map { |v| canonicalize(v) }
      else value
      end
    end

    # @return [Hash] { attempt_id:, tracked: } to go ahead and send, or
    #   { response: } to answer without sending.
    def begin_attempt(client, idempotency_key, request_hash, attachments)
      claim = @attempts.begin_attempt(
        client_id:       client['id'],
        idempotency_key: idempotency_key,
        request_hash:    request_hash,
        attachments:     attachments
      )
      return { attempt_id: claim[:attempt_id], tracked: true } if claim[:created]

      { response: replay(claim[:attempt], request_hash) }
    rescue StandardError => e
      # Without a key the attempt row is bookkeeping: send anyway, as /send
      # always has. With a key the row is the guarantee, so do not send.
      if idempotency_key
        warn "Idempotency store unavailable: #{e.class}: #{e.message}"
        return { response: json_response({ error: 'Idempotency store unavailable' }, 503) }
      end

      warn "Failed to record send attempt: #{e.message}"
      { attempt_id: nil, tracked: false }
    end

    def finish_attempt(attempt_id, result, tracked:)
      return unless tracked

      @attempts.finish_attempt(
        attempt_id,
        status:        result[:status] || (result[:success] ? 'sent' : 'failed'),
        message_id:    result[:message_id],
        smtp_response: result[:smtp_response],
        error:         result[:error]
      )
    rescue StandardError => e
      # The row stays in_progress: a retry with the same key gets 409, never a
      # second delivery.
      warn "Failed to store send attempt outcome: #{e.message}"
    end

    def replay(row, request_hash)
      unless row['request_hash'] == request_hash
        return json_response({ error: 'Idempotency-Key was already used with a different request',
                               attemptId: row['attempt_id'] }, 422)
      end

      if row['status'] == 'in_progress'
        return json_response({ error: 'A request with this Idempotency-Key is still in progress',
                               status: 'in_progress', attemptId: row['attempt_id'],
                               idempotencyKey: row['idempotency_key'] }, 409)
      end

      status, headers, body = outcome_response(
        status:          row['status'],
        attempt_id:      row['attempt_id'],
        message_id:      row['message_id'],
        smtp_response:   row['smtp_response'],
        error:           row['error'],
        idempotency_key: row['idempotency_key'],
        attachments:     Services::SendAttemptStore.attachments_of(row),
        replay:          true
      )
      [status, headers.merge('Idempotent-Replayed' => 'true'), body]
    end

    # One response shape for a fresh send and a replay. The first field(s) of
    # each branch are exactly what /send answered before attempts existed.
    def outcome_response(status:, attempt_id:, message_id:, smtp_response:, error:, idempotency_key:,
                         attachments:, replay: false)
      payload =
        case status
        when 'sent'
          { message: 'Email sent successfully' }
        when 'unknown'
          { error: 'Delivery outcome unknown, do not retry automatically', details: error }
        else
          { error: 'Failed to send email', details: error }
        end

      payload[:status]         = status
      payload[:attemptId]      = attempt_id if attempt_id
      payload[:messageId]      = message_id if message_id
      payload[:smtpResponse]   = smtp_response if smtp_response
      payload[:idempotencyKey] = idempotency_key if idempotency_key
      payload[:attachments]    = attachments unless attachments.nil? || attachments.empty?
      payload[:idempotentReplay] = true if replay

      json_response(payload, OUTCOME_HTTP_STATUS.fetch(status, 500))
    end

    def attempt_payload(row)
      payload = {
        attemptId:   row['attempt_id'],
        status:      row['status'],
        messageId:   row['message_id'],
        smtpResponse: row['smtp_response'],
        error:       row['error'],
        idempotencyKey: row['idempotency_key'],
        attachments: Services::SendAttemptStore.attachments_of(row),
        createdAt:   row['created_at']&.to_s,
        completedAt: row['completed_at']&.to_s
      }
      payload.compact
    end

    # ── Input shape ────────────────────────────────────────────────────

    # @return [Array(Array<String>, nil)] or [nil, error response]
    def address_list(raw, field)
      list = Array(raw).compact
      list = list.reject { |v| v.is_a?(String) && v.strip.empty? }
      bad = list.find { |v| !v.is_a?(String) || !v.strip.match?(ADDRESS_FORMAT) }
      return [nil, json_response({ error: "Invalid email address in #{field}", field: field }, 400)] if bad

      [list.map(&:strip).uniq, nil]
    end

    def optional_address(raw, field)
      return [nil, nil] if raw.nil? || (raw.is_a?(String) && raw.strip.empty?)
      return [nil, json_response({ error: "Invalid email address in #{field}", field: field }, 400)] unless raw.is_a?(String) && raw.strip.match?(ADDRESS_FORMAT)

      [raw.strip, nil]
    end

    # @return [Array(Hash, nil)] or [nil, error response]
    def custom_headers(raw)
      return [{}, nil] if raw.nil?
      return [nil, json_response({ error: 'headers must be an object' }, 400)] unless raw.is_a?(Hash)
      return [nil, json_response({ error: "Too many headers (max #{MAX_CUSTOM_HEADERS})" }, 400)] if raw.length > MAX_CUSTOM_HEADERS

      out = {}
      raw.each do |name, value|
        name = name.to_s
        unless name.match?(HEADER_NAME_FORMAT) && header_allowed?(name)
          return [nil, json_response({ error: "Header '#{name[0, 64]}' is not allowed (custom headers must start with X-)",
                                       field: 'headers' }, 400)]
        end
        unless value.is_a?(String) || value.is_a?(Numeric)
          return [nil, json_response({ error: "Header '#{name}' must be a string", field: 'headers' }, 400)]
        end

        text = strip_crlf(value.to_s)
        return [nil, json_response({ error: "Header '#{name}' is too long", field: 'headers' }, 400)] if text.length > MAX_HEADER_VALUE_CHARS

        out[name] = text
      end
      [out, nil]
    end

    def header_allowed?(name)
      lower = name.downcase
      lower.start_with?(ALLOWED_HEADER_PREFIX) || ALLOWED_HEADERS.include?(lower)
    end

    def strip_crlf(text)
      text.to_s.tr("\r\n", '  ')
    end

    def parse_json(request)
      body = request.body.read
      request.body.rewind
      parsed = JSON.parse(body)
      parsed.is_a?(Hash) ? parsed : {}
    rescue JSON::ParserError
      {}
    end

    def parse_json_field(value)
      return value unless value.is_a?(String)

      JSON.parse(value)
    rescue JSON::ParserError
      value
    end

    def json_response(payload, status = 200)
      [status, { 'Content-Type' => 'application/json' }, [JSON.generate(payload)]]
    end
  end
end
