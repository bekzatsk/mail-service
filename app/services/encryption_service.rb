# frozen_string_literal: true

require 'openssl'
require 'base64'
require 'digest'

module Services
  # At-rest encryption for stored credentials (clients.smtp_pass,
  # client_telegram_bots.bot_token).
  #
  # New values are AES-256-GCM, written as "v2:" + base64(iv || tag || ciphertext).
  # GCM authenticates what it decrypts, so a row that was altered — in the
  # database, in a backup, in transit — fails to decrypt instead of yielding
  # silently corrupted plaintext the way CBC does.
  #
  # Values written before the switch are AES-256-CBC, base64(iv || ciphertext)
  # with no prefix. They still decrypt, and are rewritten as GCM the next time
  # they are saved. Nothing needs re-keying.
  #
  # The key is SHA-256 of ENV['ENCRYPTION_KEY'] in both schemes.
  class EncryptionService
    GCM_PREFIX  = 'v2:'
    GCM_CIPHER  = 'aes-256-gcm'
    GCM_IV_LEN  = 12
    GCM_TAG_LEN = 16
    CBC_CIPHER  = 'aes-256-cbc'

    MIN_KEY_CHARS = 32

    def initialize
      raw_key = ENV.fetch('ENCRYPTION_KEY') { raise 'ENCRYPTION_KEY is not set' }
      raise 'ENCRYPTION_KEY is not set' if raw_key.strip.empty?

      @key = Digest::SHA256.digest(raw_key)
    end

    def encrypt(plaintext)
      cipher = OpenSSL::Cipher.new(GCM_CIPHER)
      cipher.encrypt
      cipher.key = @key
      iv = cipher.random_iv
      cipher.auth_data = ''

      encrypted = cipher.update(plaintext.to_s) + cipher.final
      GCM_PREFIX + Base64.strict_encode64(iv + cipher.auth_tag + encrypted)
    end

    def decrypt(ciphertext)
      text = ciphertext.to_s
      plain = if text.start_with?(GCM_PREFIX)
                decrypt_gcm(text.delete_prefix(GCM_PREFIX))
              else
                decrypt_cbc(text)
              end
      utf8 = plain.dup.force_encoding(Encoding::UTF_8)
      utf8.valid_encoding? ? utf8 : plain
    rescue StandardError
      # The underlying message ("bad decrypt", "unexpected length") says
      # nothing a caller should act on and is a hint to anyone probing.
      raise 'Decryption failed'
    end

    # True when the stored value is in the current scheme. Callers may use it
    # to re-encrypt legacy rows opportunistically.
    def current?(ciphertext)
      ciphertext.to_s.start_with?(GCM_PREFIX)
    end

    private

    def decrypt_gcm(encoded)
      data = Base64.strict_decode64(encoded)
      raise 'short' if data.bytesize < GCM_IV_LEN + GCM_TAG_LEN

      iv  = data[0, GCM_IV_LEN]
      tag = data[GCM_IV_LEN, GCM_TAG_LEN]
      ct  = data[(GCM_IV_LEN + GCM_TAG_LEN)..]

      decipher = OpenSSL::Cipher.new(GCM_CIPHER)
      decipher.decrypt
      decipher.key = @key
      decipher.iv = iv
      decipher.auth_tag = tag
      decipher.auth_data = ''
      decipher.update(ct) + decipher.final
    end

    def decrypt_cbc(encoded)
      data = Base64.strict_decode64(encoded)

      decipher = OpenSSL::Cipher.new(CBC_CIPHER)
      decipher.decrypt
      iv_len = decipher.iv_len
      decipher.iv  = data[0, iv_len]
      decipher.key = @key

      decipher.update(data[iv_len..]) + decipher.final
    end
  end
end
