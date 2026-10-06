# frozen_string_literal: true

module Services
  # Sanity checks on the environment before anything connects or listens.
  #
  # Fatal: a missing or placeholder ENCRYPTION_KEY. Every stored SMTP password
  # and bot token is encrypted under it, so booting with the value from
  # .env.example means encrypting them under a key anyone can read on GitHub.
  #
  # Warned, not fatal: a short MASTER_API_KEY or ENCRYPTION_KEY. Deployments
  # exist with keys that are not 64 hex characters, and refusing to start would
  # take them down rather than make them safer.
  module BootCheck
    MIN_KEY_CHARS = 32
    PLACEHOLDER = /your-|-here|changeme|example|placeholder/i

    module_function

    def run!(env = ENV)
      encryption_key = env['ENCRYPTION_KEY'].to_s.strip
      master_key     = env['MASTER_API_KEY'].to_s.strip

      abort '[boot] ENCRYPTION_KEY is not set — generate one: ruby -e "require \'securerandom\'; puts SecureRandom.hex(32)"' if encryption_key.empty?
      abort '[boot] ENCRYPTION_KEY is the placeholder from .env.example — generate a real key' if encryption_key.match?(PLACEHOLDER)

      if encryption_key.length < MIN_KEY_CHARS
        warn "[boot] WARNING: ENCRYPTION_KEY is #{encryption_key.length} characters; 64 hex characters are expected"
      end

      if master_key.empty?
        warn '[boot] WARNING: MASTER_API_KEY is not set — every admin route will answer 500'
      elsif master_key.match?(PLACEHOLDER)
        abort '[boot] MASTER_API_KEY is a placeholder — generate a real key'
      elsif master_key.length < MIN_KEY_CHARS
        warn "[boot] WARNING: MASTER_API_KEY is #{master_key.length} characters; 64 hex characters are expected"
      end
    end
  end
end
