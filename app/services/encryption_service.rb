# frozen_string_literal: true

require 'openssl'
require 'base64'
require 'digest'

module Services
  class EncryptionService
    CIPHER = 'aes-256-cbc'

    def initialize
      raw_key = ENV.fetch('ENCRYPTION_KEY') { raise 'ENCRYPTION_KEY is not set' }
      @key = Digest::SHA256.digest(raw_key)
    end

    def encrypt(plaintext)
      cipher = OpenSSL::Cipher.new(CIPHER)
      cipher.encrypt
      iv = cipher.random_iv
      cipher.key = @key

      encrypted = cipher.update(plaintext) + cipher.final
      Base64.strict_encode64(iv + encrypted)
    end

    def decrypt(ciphertext)
      data = Base64.strict_decode64(ciphertext)

      decipher = OpenSSL::Cipher.new(CIPHER)
      decipher.decrypt
      iv_len = decipher.iv_len
      decipher.iv  = data[0, iv_len]
      decipher.key = @key

      decipher.update(data[iv_len..]) + decipher.final
    rescue StandardError => e
      raise "Decryption failed: #{e.message}"
    end
  end
end
