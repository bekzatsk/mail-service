# frozen_string_literal: true

# The pieces that keep one tenant from reaching past the service: the outbound
# URL policy behind handler URLs, authenticated encryption of stored
# credentials, the response headers that make the console inert to script
# injection, and the request body cap.
#
# Pure stdlib — no database, no gems.
#
#   ruby test/security_hardening_test.rb

$LOAD_PATH.unshift File.expand_path('support', __dir__)

require 'json'
require 'base64'
require 'openssl'
require 'digest'
require 'mysql2' # resolves to test/support/mysql2.rb
require_relative 'support/assertions'

require_relative '../app/services/outbound_url_policy'
require_relative '../app/services/encryption_service'
require_relative '../app/services/boot_check'
require_relative '../app/middleware/security_headers'
require_relative '../app/middleware/body_limit'

check = Assertions.method(:check)
policy = Services::OutboundUrlPolicy

def rejected?(policy, url)
  policy.parse!(url)
  false
rescue Services::OutboundUrlPolicy::Rejected
  true
end

puts 'Outbound URL policy — syntax and literal addresses (no DNS)'
[
  'http://127.0.0.1/hook',
  'http://localhost/hook',
  'http://app.localhost/hook',
  'http://10.0.0.5:8080/hook',
  'http://172.16.3.4/hook',
  'http://192.168.1.1/hook',
  'http://169.254.169.254/latest/meta-data/',
  'http://100.64.0.1/hook',
  'http://0.0.0.0/hook',
  'http://[::1]/hook',
  'http://[::ffff:127.0.0.1]/hook',
  'http://[fe80::1]/hook',
  'http://[fc00::1]/hook',
  'ftp://example.com/hook',
  'file:///etc/passwd',
  'http://user:pass@example.com/hook',
  'http://example.com:22/hook',
  "http://example.com/hook\r\nX: y",
  'not a url',
  ''
].each do |url|
  check.call("rejects #{url.inspect[0, 48]}", rejected?(policy, url), true)
end

[
  'https://example.com/hook',
  'http://example.com/hook',
  'https://example.com:8443/hook',
  'https://hooks.example.com/telegram?bot=1',
  'http://93.184.216.34/hook',
  'http://[2606:2800:220:1:248:1893:25c8:1946]/hook'
].each do |url|
  check.call("accepts #{url}", rejected?(policy, url), false)
end

puts "\nOutbound URL policy — resolution"
check.call('literal public address resolves to itself', policy.resolve!('93.184.216.34'), '93.184.216.34')
check.call('blocked? unwraps IPv4-mapped IPv6', policy.blocked?(IPAddr.new('::ffff:10.0.0.1')), true)
check.call('blocked? passes a public address', policy.blocked?(IPAddr.new('8.8.8.8')), false)
begin
  policy.resolve!('127.0.0.1')
  check.call('resolve! refuses loopback literal', false, true)
rescue Services::OutboundUrlPolicy::Rejected
  check.call('resolve! refuses loopback literal', true, true)
end

puts "\nEncryption — AES-256-GCM with CBC fallback"
ENV['ENCRYPTION_KEY'] = 'f' * 64
enc = Services::EncryptionService.new
secret = 'smtp-password-Ω'
stored = enc.encrypt(secret)
check.call('ciphertext carries the v2 prefix', stored.start_with?('v2:'), true)
check.call('round-trips', enc.decrypt(stored), secret)
check.call('two encryptions differ (random iv)', enc.encrypt(secret) == stored, false)

raw = Base64.strict_decode64(stored.delete_prefix('v2:'))
tampered = raw.dup
tampered.setbyte(tampered.bytesize - 1, tampered.getbyte(tampered.bytesize - 1) ^ 0x01)
begin
  enc.decrypt('v2:' + Base64.strict_encode64(tampered))
  check.call('tampered ciphertext is rejected', false, true)
rescue RuntimeError => e
  check.call('tampered ciphertext is rejected', e.message, 'Decryption failed')
end

# A value written by the previous (CBC) scheme still decrypts.
cbc = OpenSSL::Cipher.new('aes-256-cbc')
cbc.encrypt
iv = cbc.random_iv
cbc.key = Digest::SHA256.digest(ENV['ENCRYPTION_KEY'])
legacy = Base64.strict_encode64(iv + cbc.update('legacy-pass') + cbc.final)
check.call('legacy CBC value decrypts', enc.decrypt(legacy), 'legacy-pass')
check.call('legacy value is reported as not current', enc.current?(legacy), false)
check.call('garbage does not leak the openssl message', (enc.decrypt('zzz') rescue $!.message), 'Decryption failed')

puts "\nBoot check"
def boot_result(env)
  Services::BootCheck.run!(env)
  :booted
rescue SystemExit
  :aborted
end
$stderr.reopen(File::NULL) # warnings are expected here
check.call('placeholder ENCRYPTION_KEY aborts', boot_result({ 'ENCRYPTION_KEY' => 'your-32-byte-hex-encryption-key-here', 'MASTER_API_KEY' => 'a' * 64 }), :aborted)
check.call('empty ENCRYPTION_KEY aborts', boot_result({ 'ENCRYPTION_KEY' => '', 'MASTER_API_KEY' => 'a' * 64 }), :aborted)
check.call('placeholder MASTER_API_KEY aborts', boot_result({ 'ENCRYPTION_KEY' => 'f' * 64, 'MASTER_API_KEY' => 'changeme' }), :aborted)
check.call('real keys boot', boot_result({ 'ENCRYPTION_KEY' => 'f' * 64, 'MASTER_API_KEY' => 'a' * 64 }), :booted)
$stderr.reopen(STDOUT)

puts "\nSecurity headers"
downstream = ->(_env) { [200, { 'Content-Type' => 'application/json' }, ['{}']] }
headers_mw = Middleware::SecurityHeaders.new(downstream)
_, api_headers, = headers_mw.call({ 'PATH_INFO' => '/admin/clients', 'rack.url_scheme' => 'https' })
check.call('CSP is set', api_headers['Content-Security-Policy'].to_s.include?("script-src 'self'"), true)
check.call('CSP forbids framing', api_headers['Content-Security-Policy'].to_s.include?("frame-ancestors 'none'"), true)
check.call('nosniff', api_headers['X-Content-Type-Options'], 'nosniff')
check.call('no referrer', api_headers['Referrer-Policy'], 'no-referrer')
check.call('API responses are no-store', api_headers['Cache-Control'], 'no-store')
check.call('HSTS on https', api_headers['Strict-Transport-Security'].to_s.start_with?('max-age='), true)
_, ui_headers, = headers_mw.call({ 'PATH_INFO' => '/ui/js/app.js', 'rack.url_scheme' => 'http' })
check.call('console assets may be cached', ui_headers.key?('Cache-Control'), false)
check.call('no HSTS on plain http', ui_headers.key?('Strict-Transport-Security'), false)
_, fwd_headers, = headers_mw.call({ 'PATH_INFO' => '/send', 'rack.url_scheme' => 'http', 'HTTP_X_FORWARDED_PROTO' => 'https' })
check.call('HSTS honours X-Forwarded-Proto', fwd_headers.key?('Strict-Transport-Security'), true)

puts "\nBody limit"
limit_mw = Middleware::BodyLimit.new(downstream, limit: 1024)
status, = limit_mw.call({ 'PATH_INFO' => '/telegram/messages', 'CONTENT_LENGTH' => '1025' })
check.call('oversize body is 413', status, 413)
status, = limit_mw.call({ 'PATH_INFO' => '/telegram/messages', 'CONTENT_LENGTH' => '1024' })
check.call('body at the limit passes', status, 200)
status, = limit_mw.call({ 'PATH_INFO' => '/send', 'CONTENT_LENGTH' => '99999999' })
check.call('/send keeps its own limit', status, 200)
status, = limit_mw.call({ 'PATH_INFO' => '/sendx', 'CONTENT_LENGTH' => '99999999' })
check.call('/sendx is not /send', status, 413)
status, = limit_mw.call({ 'PATH_INFO' => '/logs' })
check.call('no body passes', status, 200)

Assertions.report('security_hardening_test')
