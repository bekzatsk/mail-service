# frozen_string_literal: true

require 'mail'
require_relative 'database'
require_relative 'encryption_service'

module Services
  class MailService
    PRIORITY_MAP = {
      'high'   => '1 (Highest)',
      'normal' => '3 (Normal)',
      'low'    => '5 (Lowest)'
    }.freeze

    def initialize
      @encryption = EncryptionService.new
    end

    # Send an email using the client's stored SMTP configuration.
    #
    # @param client  [Hash]   Row from the clients table
    # @param params  [Hash]   Email parameters:
    #   :to       [String, Array<String>] Recipient(s)
    #   :cc       [Array<String>, nil]    CC recipients
    #   :bcc      [Array<String>, nil]    BCC recipients
    #   :reply_to [String, nil]           Reply-To address
    #   :from     [String, nil]           Override sender (default: client's from_address)
    #   :subject  [String]                Email subject
    #   :body     [String]                Email body
    #   :is_html  [Boolean, nil]          Force HTML mode (default: auto-detect)
    #   :priority [String, nil]           "high", "normal", "low"
    #   :headers  [Hash, nil]             Custom headers
    # @return [Hash] { success: Boolean, error: String|nil }
    def send(client, params)
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
        domain:               client['smtp_host']
      }

      to_list   = Array(params[:to])
      cc_list   = Array(params[:cc]).compact.reject(&:empty?)
      bcc_list  = Array(params[:bcc]).compact.reject(&:empty?)
      reply_to  = params[:reply_to]
      from_addr = params[:from] || client['from_address']
      subject   = params[:subject]
      body_text = params[:body]
      is_html   = params[:is_html].nil? ? body_text.match?(/<[a-z][\s\S]*>/i) : params[:is_html]
      priority  = params[:priority]
      custom_headers = params[:headers] || {}

      mail = Mail.new do
        from    from_addr
        to      to_list
        subject subject
      end

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

      mail.delivery_method :smtp, delivery_options
      mail.deliver!

      log(client['id'], to_list, cc_list, bcc_list, reply_to, priority, subject, 'sent')
      { success: true, error: nil }
    rescue StandardError => e
      log(client['id'], to_list, cc_list, bcc_list, reply_to, priority, subject, 'failed', e.message)
      { success: false, error: e.message }
    end

    private

    def log(client_id, to, cc, bcc, reply_to, priority, subject, status, error = nil)
      Database.query(
        'INSERT INTO mail_logs (client_id, to_address, cc, bcc, reply_to, priority, subject, status, error) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [
          client_id,
          JSON.generate(Array(to)),
          cc&.any? ? JSON.generate(cc) : nil,
          bcc&.any? ? JSON.generate(bcc) : nil,
          reply_to,
          priority,
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
