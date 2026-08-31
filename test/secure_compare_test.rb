# frozen_string_literal: true

# Services::SecureCompare guards the master key and the Telegram webhook secret.
# A short-circuiting == leaks how many leading bytes matched, which is enough to
# recover a secret one byte at a time, so the properties below are load-bearing.
#
#   ruby test/secure_compare_test.rb

require_relative '../app/services/secure_compare'
require_relative 'support/assertions'

C = Services::SecureCompare
check = Assertions.method(:check)

secret = 'f3f01878a6a5b9318d2525b21ab9718a'

puts 'Matching'
check.call('identical strings match', C.call(secret, secret), true)
check.call('empty matches empty', C.call('', ''), true)

puts "\nNot matching"
check.call('differs in the last byte', C.call("#{secret[0..-2]}X", secret), false)
check.call('differs in the first byte', C.call("X#{secret[1..]}", secret), false)
check.call('correct prefix, short', C.call(secret[0..10], secret), false)
check.call('correct prefix, long', C.call("#{secret}extra", secret), false)
check.call('empty against a secret', C.call('', secret), false)

puts "\nAbsent values are never a match"
# A missing header arrives as nil. It must not compare equal to an unset secret.
check.call('nil against nil', C.call(nil, nil), false)
check.call('nil against a secret', C.call(nil, secret), false)
check.call('a secret against nil', C.call(secret, nil), false)
check.call('nil against empty', C.call(nil, ''), false)

puts "\nNon-string input is coerced, not crashed on"
check.call('integers that match', C.call(12_345, 12_345), true)
check.call('integers that differ', C.call(12_345, 54_321), false)

puts "\nBytes, not characters"
# bytesize, not length: two strings of equal character length can differ in
# bytes, and a length-based guard would compare past the end.
check.call('multibyte equal', C.call('привет', 'привет'), true)
check.call('multibyte differing', C.call('привет', 'приветы'), false)

Assertions.report('secure compare')
