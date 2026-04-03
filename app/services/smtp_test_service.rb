# frozen_string_literal: true

require 'net/smtp'
require 'openssl'

module Services
  class SmtpTestService
    TIMEOUT = 10 # seconds

    # Test SMTP connection + authentication without sending anything.
    #
    # @param smtp_host [String]
    # @param smtp_port [Integer]
    # @param smtp_user [String]
    # @param smtp_pass [String]
    # @return [Hash] { success: Boolean, message: String }
    def test(smtp_host:, smtp_port:, smtp_user:, smtp_pass:)
      smtp_port = smtp_port.to_i
      use_ssl   = smtp_port == 465
      use_tls   = !use_ssl

      smtp = Net::SMTP.new(smtp_host, smtp_port)
      smtp.open_timeout = TIMEOUT
      smtp.read_timeout = TIMEOUT

      if use_ssl
        smtp.enable_ssl(OpenSSL::SSL::SSLContext.new)
      elsif use_tls
        smtp.enable_starttls_auto
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
