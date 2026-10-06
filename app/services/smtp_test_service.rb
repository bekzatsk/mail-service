# frozen_string_literal: true

require 'net/smtp'
require 'openssl'

module Services
  class SmtpTestService
    TIMEOUT = 10 # seconds

    # Test SMTP connection + authentication without sending anything.
    #
    # Certificate verification is on for both transports. It has to match what
    # MailService does at send time — the mail gem verifies — or a test would
    # pass against a server whose certificate the real send then rejects, and
    # the password would have been handed to an unverified peer on the way.
    #
    # @param smtp_host [String]
    # @param smtp_port [Integer]
    # @param smtp_user [String]
    # @param smtp_pass [String]
    # @return [Hash] { success: Boolean, message: String }
    def test(smtp_host:, smtp_port:, smtp_user:, smtp_pass:)
      smtp_host = smtp_host.to_s
      smtp_port = smtp_port.to_i
      return { success: false, message: 'Invalid smtp_port' } unless smtp_port.positive? && smtp_port < 65_536

      use_ssl = smtp_port == 465

      smtp = Net::SMTP.new(smtp_host, smtp_port)
      smtp.open_timeout = TIMEOUT
      smtp.read_timeout = TIMEOUT

      if use_ssl
        smtp.enable_tls(Net::SMTP.default_ssl_context)
      else
        smtp.enable_starttls_auto(Net::SMTP.default_ssl_context)
      end

      smtp.start(smtp_host, smtp_user, smtp_pass, :plain)
      smtp.finish

      { success: true, message: 'SMTP connection successful' }
    rescue Net::SMTPAuthenticationError => e
      { success: false, message: "Authentication failed: #{e.message.strip}" }
    rescue Net::OpenTimeout
      { success: false, message: "Connection timed out after #{TIMEOUT}s to #{smtp_host}:#{smtp_port}" }
    rescue Net::SMTPError, Net::SMTPFatalError => e
      { success: false, message: "SMTP error: #{e.message.strip}" }
    rescue Errno::ECONNREFUSED
      { success: false, message: "Connection refused to #{smtp_host}:#{smtp_port}" }
    rescue Errno::EHOSTUNREACH
      { success: false, message: "Host unreachable: #{smtp_host}" }
    rescue SocketError => e
      { success: false, message: "DNS/socket error: #{e.message}" }
    rescue OpenSSL::SSL::SSLError => e
      { success: false, message: "SSL/TLS error: #{e.message}" }
    rescue StandardError => e
      { success: false, message: "#{e.class}: #{e.message}" }
    end
  end
end
