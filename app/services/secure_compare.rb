# frozen_string_literal: true

module Services
  # Constant-time string comparison for secrets.
  #
  # One implementation, used by every credential check in the service: the
  # master key in ApiKeyMiddleware and the Telegram webhook secret token. A
  # short-circuiting == leaks how many leading bytes were right, which is enough
  # to recover a secret one byte at a time.
  module SecureCompare
    module_function

    def call(given, expected)
      return false if given.nil? || expected.nil?

      given = given.to_s
      expected = expected.to_s
      return false unless given.bytesize == expected.bytesize

      result = 0
      given.bytes.zip(expected.bytes) { |a, b| result |= a ^ b }
      result.zero?
    end
  end
end
