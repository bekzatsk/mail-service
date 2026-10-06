# frozen_string_literal: true

require 'mail'
require 'json'
require 'securerandom'
require_relative 'database'
require_relative 'encryption_service'

module Services
  class MailService
    PRIORITY_MAP = {
      'high'   => '1 (Highest)',
      'normal' => '3 (Normal)',
      'low'    => '5 (Lowest)'
    }.freeze

    DEFAULT_OPEN_TIMEOUT = 10
    DEFAULT_READ_TIMEOUT = 60
    MAX_ERROR_CHARS = 1000

    # Mail::SMTP that remembers how far the SMTP dialogue got. The phase is
    # what separates a definite failure from an unknown outcome:
    #
    #   :connect / :envelope  nothing was handed over      -> failed
    #   :data                 body sent, final reply lost  -> unknown
    #   :accepted             server answered 250 to DATA  -> sent
    class TrackedSMTP < Mail::SMTP
      module PhaseTracking
        attr_accessor :phase_tracker

        def mailfrom(*args)
          phase_tracker.phase = :envelope
          super
        end

        def data(*args, &block)
          phase_tracker.phase = :data
          response = super
          phase_tracker.phase = :accepted
          response
        end
      end

      attr_accessor :phase

      def deliver!(mail)
        self.phase = :connect
        super
      end

      private

      def build_smtp_session
        super.tap do |smtp|
          smtp.extend(PhaseTracking)
          smtp.phase_tracker = self
        end
      end
    end

    # @param delivery_method [Array, nil] override for tests, e.g.
    #   [Mail::TestMailer, {}]. Production leaves it nil and gets TrackedSMTP
    #   built from the client's stored SMTP settings.
    def initialize(delivery_method: nil)
      @encryption = EncryptionService.new
      @delivery_method = delivery_method
    end

    # Send an email using the client's stored SMTP configuration.
    #
    # @param client  [Hash]   Row from the clients table
    # @param params  [Hash]   Email parameters:
    #   :to          [String, Array<String>] Recipient(s)
    #   :cc          [Array<String>, nil]    CC recipients
    #   :bcc         [Array<String>, nil]    BCC recipients
    #   :reply_to    [String, nil]           Reply-To address
    #   :from        [String, nil]           Override sender (default: client's from_address)
    #   :subject     [String]                Email subject
    #   :body        [String]                Email body
    #   :is_html     [Boolean, nil]          Force HTML mode (default: auto-detect)
    #   :priority    [String, nil]           "high", "normal", "low"
    #   :headers     [Hash, nil]             Custom headers
    #   :attachments [Array<AttachmentValidator::Attachment>, nil] Already validated
    #   :attempt_id  [String, nil]           mail_send_attempts.attempt_id, also used for Message-ID
    # @return [Hash] { success:, error:, status: 'sent'|'failed'|'unknown', message_id:, smtp_response: }
    def send(client, params)
      attempt_id  = params[:attempt_id] || SecureRandom.uuid
      to_list     = Array(params[:to])
      cc_list     = Array(params[:cc]).compact.reject(&:empty?)
      bcc_list    = Array(params[:bcc]).compact.reject(&:empty?)
      reply_to    = params[:reply_to]
      priority    = params[:priority]
      subject     = params[:subject]
      attachments = Array(params[:attachments])
      log_context = { attempt_id: params[:attempt_id], attachments: attachments }
      message_id  = nil
      mail        = nil

      smtp_pass = @encryption.decrypt(client['smtp_pass'])
      smtp_port = client['smtp_port'].to_i

      delivery_options = {
        address:              client['smtp_host'],
        port:                 smtp_port,
        user_name:            client['smtp_user'],
        password:             smtp_pass,
        authentication:       :plain,
        enable_starttls_auto: smtp_port != 465,
        ssl:                  smtp_port == 465,
        domain:               client['smtp_host'],
        open_timeout:         timeout_env('MAIL_SMTP_OPEN_TIMEOUT_SECONDS', DEFAULT_OPEN_TIMEOUT),
        read_timeout:         timeout_env('MAIL_SMTP_READ_TIMEOUT_SECONDS', DEFAULT_READ_TIMEOUT),
        return_response:      true
      }

      from_addr = params[:from] || client['from_address']
      body_text = params[:body]
      is_html   = params[:is_html].nil? ? body_text.match?(/<[a-z][\s\S]*>/i) : params[:is_html]
      custom_headers = params[:headers] || {}

      mail = Mail.new do
        from    from_addr
        to      to_list
        subject subject
      end

      # Our own Message-ID, so the caller learns it even when the outcome is
      # unknown, and can find the message in the recipient's mailbox.
      message_id = "#{attempt_id}@#{message_id_domain(from_addr, client['smtp_host'])}"
      mail.message_id = "<#{message_id}>"

      # Optional fields
      mail.cc       = cc_list   unless cc_list.empty?
      mail.bcc      = bcc_list  unless bcc_list.empty?
      mail.reply_to = reply_to  if reply_to && !reply_to.empty?

      # Priority
      if priority && PRIORITY_MAP.key?(priority)
        mail['X-Priority'] = PRIORITY_MAP[priority]
        mail['X-MSMail-Priority'] = priority.capitalize
        mail['Importance'] = priority == 'high' ? 'High' : (priority == 'low' ? 'Low' : 'Normal')
      end

      # Custom headers
      custom_headers.each do |key, value|
        mail[key.to_s] = value.to_s
      end

      # Body
      if attachments.empty?
        build_body(mail, body_text, is_html)
      else
        build_body_with_attachments(mail, body_text, is_html, attachments)
      end

      if @delivery_method
        mail.delivery_method(*@delivery_method)
      else
        mail.delivery_method TrackedSMTP, delivery_options
      end
      response = mail.deliver!

      smtp_response = response.is_a?(Net::SMTP::Response) ? response.string.to_s.strip : nil
      log(client['id'], to_list, cc_list, bcc_list, reply_to, priority, subject, 'sent', nil, **log_context)
      { success: true, error: nil, status: 'sent', message_id: message_id, smtp_response: smtp_response }
    rescue StandardError => e
      status = classify_failure(e, delivery_phase(mail))
      error  = e.message.to_s[0, MAX_ERROR_CHARS]
      log(client['id'], to_list, cc_list, bcc_list, reply_to, priority, subject, status, error, **log_context)
      { success: false, error: error, status: status, message_id: message_id, smtp_response: nil }
    end

    # Decides what an exception means for delivery, given how far the SMTP
    # dialogue got.
    #
    # Only a failure while the message body is in flight is ambiguous: the
    # server may have queued it and the reply got lost. An explicit SMTP error
    # reply at that stage (4xx/5xx after DATA) is still a definite "no".
    # An unknown outcome must never be retried automatically.
    def classify_failure(error, phase)
      case phase
      when :accepted
        'sent'
      when :data
        definite_smtp_rejection?(error) ? 'failed' : 'unknown'
      else
        'failed'
      end
    end

    private

    def build_body(mail, body_text, is_html)
      if is_html
        mail.html_part do
          content_type 'text/html; charset=UTF-8'
          body body_text
        end

        mail.text_part do
          content_type 'text/plain; charset=UTF-8'
          body body_text.gsub(/<[^>]+>/, '')
        end
      else
        mail.body = body_text
        mail.charset = 'UTF-8'
      end
    end

    # multipart/mixed
    #   text/plain                      (plain body)
    #   | multipart/alternative         (HTML body)
    #   |   text/plain, text/html
    #   attachment...
    def build_body_with_attachments(mail, body_text, is_html, attachments)
      if is_html
        alternative = Mail::Part.new { content_type 'multipart/alternative' }
        alternative.add_part(text_part(body_text.gsub(/<[^>]+>/, '')))
        alternative.add_part(Mail::Part.new do
          content_type 'text/html; charset=UTF-8'
          body body_text
        end)
        mail.add_part(alternative)
      else
        mail.add_part(text_part(body_text))
      end

      attachments.each do |attachment|
        mail.attachments[attachment.filename] = {
          mime_type:    attachment.content_type,
          # name= gets RFC 2231 encoding from the mail gem; filename= in
          # Content-Disposition gets an RFC 2047 encoded-word. Clients read one
          # or the other, so non-ASCII names survive in both.
          content_type: %(#{attachment.content_type}; name="#{attachment.filename}"),
          content:      attachment.content
        }
      end
    end

    def text_part(text)
      Mail::Part.new do
        content_type 'text/plain; charset=UTF-8'
        body text
      end
    end

    def definite_smtp_rejection?(error)
      error.is_a?(Net::SMTPError) && !error.is_a?(Net::SMTPUnknownError)
    end

    def delivery_phase(mail)
      method = mail&.delivery_method
      method.respond_to?(:phase) ? method.phase : nil
    rescue StandardError
      nil
    end

    def message_id_domain(from_addr, smtp_host)
      domain = begin
        Mail::Address.new(from_addr.to_s).domain
      rescue StandardError
        nil
      end
      domain = smtp_host if domain.nil? || domain.empty?
      domain = 'mail-service.local' if domain.nil? || domain.to_s.empty?
      domain.to_s.downcase
    end

    def timeout_env(name, default)
      value = Integer(ENV[name].to_s.strip, 10)
      value.positive? ? value : default
    rescue ArgumentError, TypeError
      default
    end

    def log(client_id, to, cc, bcc, reply_to, priority, subject, status, error = nil, attempt_id: nil, attachments: [])
      attachment_meta = Array(attachments).map { |a| a.respond_to?(:metadata) ? a.metadata : a }
      Database.query(
        'INSERT INTO mail_logs (client_id, attempt_id, to_address, cc, bcc, reply_to, priority, attachments, subject, status, error) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [
          client_id,
          attempt_id,
          JSON.generate(Array(to)),
          cc&.any? ? JSON.generate(cc) : nil,
          bcc&.any? ? JSON.generate(bcc) : nil,
          reply_to,
          priority,
          attachment_meta.empty? ? nil : JSON.generate(attachment_meta),
          subject,
          status,
          error
        ]
      )
    rescue StandardError => e
      warn "Failed to write mail log: #{e.message}"
    end
  end
end
