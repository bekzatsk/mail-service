# frozen_string_literal: true

require 'mail'
require_relative 'database'
require_relative 'encryption_service'

module Services
  class MailService
    def initialize
      @encryption = EncryptionService.new
    end

    # Send an email using the client's stored SMTP configuration.
    #
    # @param client [Hash]  Row from the clients table
    # @param to     [String] Recipient email address
    # @param subject [String] Email subject
    # @param body   [String] Email body (HTML)
    # @return [Hash] { success: Boolean, error: String|nil }
    def send(client, to, subject, body)
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

      mail = Mail.new do
        from    client['from_address']
        to      to
        subject subject

        html_part do
          content_type 'text/html; charset=UTF-8'
          body body
        end

        text_part do
          content_type 'text/plain; charset=UTF-8'
          body body.gsub(/<[^>]+>/, '')
        end
      end

      mail.delivery_method :smtp, delivery_options
      mail.deliver!

      log(client['id'], to, subject, 'sent')
      { success: true, error: nil }
    rescue StandardError => e
      log(client['id'], to, subject, 'failed', e.message)
      { success: false, error: e.message }
    end

    private

    def log(client_id, to, subject, status, error = nil)
      Database.query(
        'INSERT INTO mail_logs (client_id, to_address, subject, status, error) VALUES (?, ?, ?, ?, ?)',
        [client_id, to, subject, status, error]
      )
    rescue StandardError => e
      warn "Failed to write mail log: #{e.message}"
    end
  end
end
