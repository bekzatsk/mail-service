# frozen_string_literal: true

# POST /send end to end, minus the network: attachments, the MIME structure
# that comes out, backward compatibility of calls without attachments,
# idempotency, delivery outcome classification, GET /send/:attemptId, and that
# no attachment payload reaches a log.
#
# Needs the `mail` gem (the only gem MailService uses). No database — an
# in-memory stand-in plays mail_send_attempts and mail_logs. No real SMTP —
# messages go to Mail::TestMailer, and the SMTP-path checks talk to a fake
# server on 127.0.0.1 started by this file.
#
#   ruby test/mail_send_test.rb

$LOAD_PATH.unshift File.expand_path('support', __dir__)

require 'json'
require 'stringio'
require 'socket'
require 'mysql2' # resolves to test/support/mysql2.rb
require_relative 'support/assertions'

ENV['ENCRYPTION_KEY'] ||= '0' * 64
ENV.delete('MAIL_MAX_REQUEST_BYTES')

begin
  require 'mail'
rescue LoadError
  abort 'mail_send_test needs the mail gem: gem install mail --no-document'
end

require_relative '../app/handlers/mail_handler'

# ── In-memory database ───────────────────────────────────────────────────────
#
# Understands exactly the statements SendAttemptStore and MailService#log
# issue, and records every call so the tests can inspect what was persisted.
class FakeDB
  class DuplicateEntry < StandardError
    def error_number = 1062
  end

  attr_reader :attempts, :mail_logs, :calls

  def initialize
    reset!
  end

  def reset!
    @attempts = []
    @mail_logs = []
    @calls = []
  end

  def query(sql, params = [])
    @calls << [sql, params]
    raise "placeholder mismatch in: #{sql}" unless sql.count('?') == params.length

    case sql
    when /INSERT INTO mail_send_attempts/
      attempt_id, client_id, key, request_hash, status, attachments = params
      if key && @attempts.any? { |r| r['client_id'] == client_id && r['idempotency_key'] == key }
        raise DuplicateEntry, "Duplicate entry '#{client_id}-#{key}' for key 'uniq_mail_send_idempotency'"
      end

      @attempts << { 'attempt_id' => attempt_id, 'client_id' => client_id, 'idempotency_key' => key,
                     'request_hash' => request_hash, 'status' => status, 'attachments' => attachments,
                     'message_id' => nil, 'smtp_response' => nil, 'error' => nil,
                     'created_at' => Time.now, 'completed_at' => nil }
      nil
    when /UPDATE mail_send_attempts SET idempotency_key = NULL/
      client_id, key, hours = params
      @attempts.each do |r|
        next unless r['client_id'] == client_id && r['idempotency_key'] == key
        next unless r['created_at'] < Time.now - (hours * 3600)

        r['idempotency_key'] = nil
      end
      nil
    when /UPDATE mail_send_attempts/
      status, message_id, smtp_response, error, attempt_id = params
      row = @attempts.find { |r| r['attempt_id'] == attempt_id && r['status'] == 'in_progress' }
      row&.merge!('status' => status, 'message_id' => message_id, 'smtp_response' => smtp_response,
                  'error' => error, 'completed_at' => Time.now)
      nil
    when /FROM mail_send_attempts WHERE attempt_id = \? AND client_id = \?/
      @attempts.select { |r| r['attempt_id'] == params[0] && r['client_id'] == params[1] }.map(&:dup)
    when /FROM mail_send_attempts WHERE client_id = \? AND idempotency_key = \?/
      @attempts.select { |r| r['client_id'] == params[0] && r['idempotency_key'] == params[1] }.map(&:dup)
    when /INSERT INTO mail_logs/
      cols = sql[/\(([^)]*)\) VALUES/, 1].split(',').map(&:strip)
      @mail_logs << cols.zip(params).to_h
      nil
    else
      raise "FakeDB does not understand: #{sql}"
    end
  end
end

DB = FakeDB.new

module Services
  class Database
    def self.query(sql, params = []) = DB.query(sql, params)
  end
end

# ── Fixtures ────────────────────────────────────────────────────────────────

SMTP_PASS = Services::EncryptionService.new.encrypt('test-password')

def client_row(id: 1, port: 2525)
  { 'id' => id, 'organization_id' => 7, 'smtp_host' => '127.0.0.1', 'smtp_port' => port,
    'smtp_user' => 'user@altyn.test', 'smtp_pass' => SMTP_PASS, 'from_address' => 'crm@altyn.test' }
end

CLIENT = client_row.freeze
OTHER_CLIENT = client_row(id: 2).freeze

PDF = "%PDF-1.7\n%\xE2\xE3\xCF\xD3\n1 0 obj << /Type /Catalog >> endobj\ntrailer << >>\n%%EOF\n".b
PDF_B64 = [PDF].pack('m0')
CYRILLIC_NAME = 'КП_REQ-1042_v3.pdf'

class FakeRequest
  attr_reader :env

  def initialize(payload, headers = {})
    @raw = payload.is_a?(String) ? payload : JSON.generate(payload)
    @env = { 'CONTENT_LENGTH' => @raw.bytesize.to_s }.merge(headers)
  end

  def body = (@body ||= StringIO.new(@raw))
end

def crm_payload(extra = {})
  {
    'to' => 'client@example.com',
    'subject' => 'Коммерческое предложение REQ-1042',
    'body' => 'Направляем согласованное предложение.',
    'attachments' => [{ 'filename' => CYRILLIC_NAME, 'contentType' => 'application/pdf', 'contentBase64' => PDF_B64 }]
  }.merge(extra)
end

# A delivery method that fails the way a chosen SMTP phase would.
class ScriptedDelivery
  attr_accessor :settings, :phase

  class << self
    attr_accessor :calls
  end
  self.calls = 0

  def initialize(settings)
    @settings = settings
  end

  def deliver!(_mail)
    self.class.calls += 1
    self.phase = settings[:phase]
    raise settings[:error] if settings[:error]

    self
  end
end

def handler_with(delivery, validator: nil)
  Handlers::MailHandler.new(
    mail_service: Services::MailService.new(delivery_method: delivery),
    attempts:     Services::SendAttemptStore.new(ttl_hours: 24, database: DB),
    validator:    validator || Services::AttachmentValidator.new
  )
end

TEST_HANDLER = handler_with([Mail::TestMailer, {}])

def deliveries = Mail::TestMailer.deliveries

def reset!
  DB.reset!
  deliveries.clear
  ScriptedDelivery.calls = 0
end

def post(handler, payload, headers = {}, client: CLIENT)
  status, response_headers, body = handler.send_mail(FakeRequest.new(payload, headers), client)
  [status, JSON.parse(body.first), response_headers]
end

def reparse(message) = Mail.read_from_string(message.encoded)

check = Assertions.method(:check)

# ── Backward compatibility ──────────────────────────────────────────────────

puts 'Calls without attachments behave as before'
reset!
status, body, = post(TEST_HANDLER, { 'to' => 'a@example.com', 'subject' => 'Hi', 'body' => 'Plain text' })
check.call('200', status, 200)
check.call('message is unchanged', body['message'], 'Email sent successfully')
check.call('status sent', body['status'], 'sent')
check.call('attemptId is a UUID', body['attemptId'].to_s.match?(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/), true)
check.call('messageId is returned', body['messageId'], "#{body['attemptId']}@altyn.test")
check.call('no attachments field', body.key?('attachments'), false)
check.call('exactly one delivery', deliveries.size, 1)
m = reparse(deliveries.last)
check.call('plain message is still single-part', m.multipart?, false)
check.call('plain message is still text/plain UTF-8', [m.mime_type, m.charset.downcase], ['text/plain', 'utf-8'])
check.call('Message-ID header is the returned messageId', m.message_id, body['messageId'])
check.call('the attempt is stored as sent', DB.attempts.map { |r| r['status'] }, ['sent'])
check.call('mail_logs row links the attempt', DB.mail_logs.last['attempt_id'], body['attemptId'])
check.call('mail_logs row has no attachments', DB.mail_logs.last['attachments'], nil)

reset!
post(TEST_HANDLER, { 'to' => ['a@example.com'], 'body' => '<p>Hello <b>there</b></p>' })
m = reparse(deliveries.last)
check.call('HTML without attachments is still multipart/alternative', m.mime_type, 'multipart/alternative')
check.call('with text and html parts', m.parts.map(&:mime_type).sort, %w[text/html text/plain])

reset!
status, body, = post(TEST_HANDLER, { 'subject' => 'no recipient' })
check.call('missing to is still 400 with the same error', [status, body], [400, { 'error' => 'Missing required field: to' }])
status, = post(TEST_HANDLER, 'not json')
check.call('malformed JSON is still 400 (missing to)', status, 400)
check.call('nothing was delivered for invalid requests', deliveries.size, 0)

# ── Attachments and MIME structure ──────────────────────────────────────────

puts "\nA PDF attachment with a Cyrillic filename"
reset!
status, body, = post(TEST_HANDLER, crm_payload)
check.call('200 sent', [status, body['status']], [200, 'sent'])
check.call('response lists attachment metadata',
           body['attachments'], [{ 'filename' => CYRILLIC_NAME, 'contentType' => 'application/pdf',
                                   'size' => PDF.bytesize, 'sha256' => Digest::SHA256.hexdigest(PDF) }])
raw = deliveries.last.encoded
m = Mail.read_from_string(raw)
check.call('message is multipart/mixed', m.mime_type, 'multipart/mixed')
check.call('parts: body then PDF', m.parts.map(&:mime_type), %w[text/plain application/pdf])
check.call('body part is UTF-8 text', m.parts.first.decoded.force_encoding('UTF-8'),
           'Направляем согласованное предложение.')
att = m.attachments.first
check.call('one attachment', m.attachments.size, 1)
check.call('attachment filename decodes to Cyrillic', att.filename, CYRILLIC_NAME)
check.call('attachment bytes round-trip exactly', att.decoded.b, PDF)
check.call('Content-Disposition is attachment', att.content_disposition.start_with?('attachment'), true)
check.call('attachment is base64 transfer-encoded', att.content_transfer_encoding, 'base64')
check.call('Content-Type name uses RFC 2231', raw.include?("name*=utf-8'"), true)
check.call('Content-Disposition filename uses an RFC 2047 word', raw.include?('filename="=?UTF-8?B?'), true)
check.call('raw headers are 7-bit clean', raw.lines.take_while { |l| l != "\r\n" }.join.ascii_only?, true)
check.call('subject decodes to Cyrillic', m.subject, 'Коммерческое предложение REQ-1042')

reset!
post(TEST_HANDLER, crm_payload('body' => '<p>Направляем <b>КП</b></p>', 'isHtml' => true))
m = reparse(deliveries.last)
check.call('HTML + attachment: mixed at the root', m.mime_type, 'multipart/mixed')
check.call('HTML + attachment: alternative then PDF', m.parts.map(&:mime_type), %w[multipart/alternative application/pdf])
check.call('alternative holds text then html', m.parts.first.parts.map(&:mime_type), %w[text/plain text/html])

reset!
two = crm_payload('attachments' => crm_payload['attachments'] * 2)
two['attachments'][1] = two['attachments'][1].merge('filename' => 'Смета.pdf')
post(TEST_HANDLER, two)
check.call('two attachments', reparse(deliveries.last).attachments.map(&:filename), [CYRILLIC_NAME, 'Смета.pdf'])

# ── Validation over HTTP ────────────────────────────────────────────────────

puts "\nInvalid attachments are rejected before anything is sent"
reset!
bad = lambda do |attachment_overrides, handler = TEST_HANDLER|
  payload = crm_payload('attachments' => [crm_payload['attachments'].first.merge(attachment_overrides)])
  status, body, = post(handler, payload)
  [status, body['error'], body['field']]
end
check.call('image/png -> 415', bad.call('contentType' => 'image/png'),
           [415, 'Invalid attachment', 'attachments[0].contentType'])
check.call('bad base64 -> 400', bad.call('contentBase64' => '%%%'),
           [400, 'Invalid attachment', 'attachments[0].contentBase64'])
check.call('non-PDF bytes -> 400', bad.call('contentBase64' => ['MZ fake exe'].pack('m0')),
           [400, 'Invalid attachment', 'attachments[0].contentBase64'])
check.call('missing filename -> 400', bad.call('filename' => ''),
           [400, 'Invalid attachment', 'attachments[0].filename'])
tiny = handler_with([Mail::TestMailer, {}], validator: Services::AttachmentValidator.new(max_bytes: 32))
check.call('over the size limit -> 413', bad.call({}, tiny),
           [413, 'Invalid attachment', 'attachments[0].contentBase64'])
status, body, = post(TEST_HANDLER, crm_payload('attachments' => 'КП.pdf'))
check.call('attachments not an array -> 400', [status, body['field']], [400, 'attachments'])
status, body, = post(TEST_HANDLER, crm_payload('attachments' => Array.new(6) { crm_payload['attachments'].first }))
check.call('more than 5 -> 413', [status, body['field']], [413, 'attachments'])
check.call('no delivery for any of them', deliveries.size, 0)
check.call('no attempt recorded for any of them', DB.attempts.size, 0)

req = FakeRequest.new(crm_payload)
req.env['CONTENT_LENGTH'] = (TEST_HANDLER.send(:max_request_bytes) + 1).to_s
status, = TEST_HANDLER.send_mail(req, CLIENT)
check.call('body over the request limit -> 413', status, 413)

# ── Idempotency ─────────────────────────────────────────────────────────────

puts "\nIdempotency-Key: same key, one delivery"
reset!
key = { 'HTTP_IDEMPOTENCY_KEY' => 'crm-req-1042-v3' }
s1, b1, h1 = post(TEST_HANDLER, crm_payload, key)
s2, b2, h2 = post(TEST_HANDLER, crm_payload, key)
check.call('first call sends', [s1, b1['status']], [200, 'sent'])
check.call('second call replays the same result', [s2, b2['status']], [200, 'sent'])
check.call('same attemptId', b2['attemptId'], b1['attemptId'])
check.call('same messageId', b2['messageId'], b1['messageId'])
check.call('replay is flagged in the body', [b1['idempotentReplay'], b2['idempotentReplay']], [nil, true])
check.call('replay is flagged in a header', [h1['Idempotent-Replayed'], h2['Idempotent-Replayed']], [nil, 'true'])
check.call('replay repeats attachment metadata', b2['attachments'], b1['attachments'])
check.call('exactly one delivery', deliveries.size, 1)
check.call('exactly one attempt row', DB.attempts.size, 1)

s3, b3, = post(TEST_HANDLER, crm_payload('subject' => 'Другое письмо'), key)
check.call('same key, different payload -> 422', [s3, b3['attemptId']], [422, b1['attemptId']])
other_pdf = crm_payload('attachments' => [crm_payload['attachments'].first.merge(
  'contentBase64' => ["#{PDF}% v4\n".b].pack('m0')
)])
s4, = post(TEST_HANDLER, other_pdf, key)
check.call('same key, different PDF bytes -> 422', s4, 422)
check.call('still one delivery', deliveries.size, 1)

s5, b5, = post(TEST_HANDLER, crm_payload, key, client: OTHER_CLIENT)
check.call('another client may use the same key', [s5, b5['status']], [200, 'sent'])
check.call('...and gets its own attempt', b5['attemptId'] == b1['attemptId'], false)

reset!
s6, = post(TEST_HANDLER, crm_payload('idempotencyKey' => 'body-key'))
s7, b7, = post(TEST_HANDLER, crm_payload('idempotencyKey' => 'body-key'))
check.call('idempotencyKey in the body works too', [s6, s7, b7['idempotentReplay'], deliveries.size], [200, 200, true, 1])
s8, = post(TEST_HANDLER, crm_payload('idempotencyKey' => 'a'), { 'HTTP_IDEMPOTENCY_KEY' => 'b' })
check.call('header and body disagreeing -> 400', s8, 400)
s9, = post(TEST_HANDLER, crm_payload, { 'HTTP_IDEMPOTENCY_KEY' => 'has spaces in it' })
check.call('malformed key -> 400', s9, 400)
s10, = post(TEST_HANDLER, crm_payload, { 'HTTP_IDEMPOTENCY_KEY' => 'k' * 256 })
check.call('key over 255 chars -> 400', s10, 400)

puts "\nIdempotency-Key: a request still in flight"
reset!
DB.query('INSERT INTO mail_send_attempts (attempt_id, client_id, idempotency_key, request_hash, status, attachments)
          VALUES (?, ?, ?, ?, ?, ?)',
         ['11111111-2222-4333-8444-555555555555', CLIENT['id'], 'in-flight',
          TEST_HANDLER.send(:request_fingerprint, {
            to: ['client@example.com'], cc: [], bcc: [], reply_to: nil, from: nil,
            subject: 'Коммерческое предложение REQ-1042', body: 'Направляем согласованное предложение.',
            is_html: nil, priority: nil, headers: {},
            attachments: Services::AttachmentValidator.new.validate(crm_payload['attachments'])
          }), 'in_progress', nil])
status, body, = post(TEST_HANDLER, crm_payload, { 'HTTP_IDEMPOTENCY_KEY' => 'in-flight' })
check.call('-> 409 in_progress', [status, body['status'], body['attemptId']],
           [409, 'in_progress', '11111111-2222-4333-8444-555555555555'])
check.call('nothing was sent', deliveries.size, 0)

puts "\nIdempotency-Key: the retention window"
DB.attempts.first['created_at'] = Time.now - (25 * 3600)
DB.attempts.first['status'] = 'sent'
status, body, = post(TEST_HANDLER, crm_payload, { 'HTTP_IDEMPOTENCY_KEY' => 'in-flight' })
check.call('an expired key is free again', [status, body['idempotentReplay']], [200, nil])
check.call('the old attempt is kept, only unkeyed', DB.attempts.first['idempotency_key'], nil)

puts "\nIdempotency-Key: store unavailable"
broken_store = Object.new
def broken_store.begin_attempt(**) = raise('Lost connection to MySQL server')
broken = Handlers::MailHandler.new(mail_service: Services::MailService.new(delivery_method: [Mail::TestMailer, {}]),
                                   attempts: broken_store, validator: Services::AttachmentValidator.new)
reset!
status, = post(broken, crm_payload, { 'HTTP_IDEMPOTENCY_KEY' => 'k1' })
check.call('with a key: 503 and nothing sent', [status, deliveries.size], [503, 0])
status, body, = post(broken, crm_payload)
check.call('without a key: sends as /send always has', [status, body['status'], deliveries.size], [200, 'sent', 1])
check.call('...with no attemptId to offer', body.key?('attemptId'), false)

# ── Outcome classification ──────────────────────────────────────────────────

puts "\nsent / failed / unknown"
scenarios = {
  'refused at connect -> failed' => [:connect, Errno::ECONNREFUSED.new, 500, 'failed'],
  'auth rejected -> failed' => [:connect, Net::SMTPAuthenticationError.new('535 5.7.8 bad credentials'), 500, 'failed'],
  'recipient rejected -> failed' => [:envelope, Net::SMTPFatalError.new('550 5.1.1 no such user'), 500, 'failed'],
  'timeout before DATA -> failed' => [:envelope, Net::ReadTimeout.new, 500, 'failed'],
  'server rejects after DATA -> failed' => [:data, Net::SMTPFatalError.new('554 5.7.1 rejected'), 500, 'failed'],
  'timeout after DATA -> unknown' => [:data, Net::ReadTimeout.new, 504, 'unknown'],
  'connection dropped after DATA -> unknown' => [:data, EOFError.new('end of file reached'), 504, 'unknown'],
  'connection reset after DATA -> unknown' => [:data, Errno::ECONNRESET.new, 504, 'unknown'],
  'garbled reply after DATA -> unknown' => [:data, Net::SMTPUnknownError.new('???'), 504, 'unknown'],
  'QUIT fails after 250 -> sent' => [:accepted, EOFError.new, 200, 'sent']
}
scenarios.each do |label, (phase, error, http, outcome)|
  reset!
  handler = handler_with([ScriptedDelivery, { phase: phase, error: error }])
  status, body, = post(handler, crm_payload, { 'HTTP_IDEMPOTENCY_KEY' => "k-#{label.hash}" })
  check.call(label, [status, body['status'], DB.attempts.first['status'], DB.mail_logs.first['status']],
             [http, outcome, outcome, outcome])
end

reset!
unknown = handler_with([ScriptedDelivery, { phase: :data, error: Net::ReadTimeout.new }])
_, first, = post(unknown, crm_payload, { 'HTTP_IDEMPOTENCY_KEY' => 'unknown-1' })
_, again, = post(unknown, crm_payload, { 'HTTP_IDEMPOTENCY_KEY' => 'unknown-1' })
check.call('unknown: the service itself tried once', ScriptedDelivery.calls, 1)
check.call('unknown: a retry with the key replays unknown, no resend',
           [again['status'], again['idempotentReplay'], again['attemptId'] == first['attemptId'], ScriptedDelivery.calls],
           ['unknown', true, true, 1])
check.call('unknown: messageId is still known', first['messageId'].to_s.end_with?('@altyn.test'), true)

reset!
failing = handler_with([ScriptedDelivery, { phase: :envelope, error: Net::SMTPFatalError.new('550 no such user') }])
post(failing, crm_payload, { 'HTTP_IDEMPOTENCY_KEY' => 'failed-1' })
status, body, = post(failing, crm_payload, { 'HTTP_IDEMPOTENCY_KEY' => 'failed-1' })
check.call('failed: a retry with the same key replays failed, no resend',
           [status, body['status'], body['details'], ScriptedDelivery.calls], [500, 'failed', '550 no such user', 1])

# ── GET /send/:attemptId ────────────────────────────────────────────────────

puts "\nGET /send/:attemptId"
reset!
_, sent, = post(TEST_HANDLER, crm_payload, { 'HTTP_IDEMPOTENCY_KEY' => 'lookup' })
status, _, body = TEST_HANDLER.show_attempt(CLIENT, sent['attemptId'])
found = JSON.parse(body.first)
check.call('own attempt -> 200', status, 200)
check.call('status, messageId, key', [found['status'], found['messageId'], found['idempotencyKey']],
           ['sent', sent['messageId'], 'lookup'])
check.call('attachment metadata', found['attachments'], sent['attachments'])
check.call('timestamps', [found['createdAt'].nil?, found['completedAt'].nil?], [false, false])
status, = TEST_HANDLER.show_attempt(OTHER_CLIENT, sent['attemptId'])
check.call("another client's attempt -> 404", status, 404)
status, = TEST_HANDLER.show_attempt(CLIENT, "' OR 1=1 --")
check.call('malformed id -> 404', status, 404)
status, = TEST_HANDLER.show_attempt(CLIENT, '00000000-0000-4000-8000-000000000000')
check.call('unknown id -> 404', status, 404)

# ── Nothing persists or logs attachment content ─────────────────────────────

puts "\nNo attachment payload in storage or logs"
reset!
captured = StringIO.new
$stderr = captured
$stdout = captured
begin
  post(TEST_HANDLER, crm_payload, { 'HTTP_IDEMPOTENCY_KEY' => 'no-payload-logs' })
  post(handler_with([ScriptedDelivery, { phase: :data, error: Net::ReadTimeout.new }]), crm_payload)
  post(broken, crm_payload) # warns about the store
ensure
  $stderr = STDERR
  $stdout = STDOUT
end
persisted = JSON.generate(DB.calls.map(&:last))
needle = PDF_B64[20, 40]
check.call('no base64 in any DB write', persisted.include?(needle), false)
check.call('no raw PDF bytes in any DB write', persisted.include?('/Type /Catalog'), false)
check.call('no base64 on stdout/stderr', captured.string.include?(needle), false)
log_meta = JSON.parse(DB.mail_logs.first['attachments'])
check.call('mail_logs keeps metadata only', log_meta.first.keys.sort, %w[contentType filename sha256 size])
attempt_meta = JSON.parse(DB.attempts.first['attachments'])
check.call('mail_send_attempts keeps metadata only', attempt_meta.first.keys.sort, %w[contentType filename sha256 size])

# ── The real SMTP path, against a fake server on localhost ──────────────────
#
# TrackedSMTP is what production uses. These drive it through Net::SMTP to a
# scripted server so the phase tracking is proven on the real code path.

class FakeSMTPServer
  attr_reader :port, :messages

  # after_data: :accept (250), :reject (554) or :drop (close without a reply)
  def initialize(after_data)
    @after_data = after_data
    @messages = []
    @server = TCPServer.new('127.0.0.1', 0)
    @port = @server.addr[1]
    @thread = Thread.new { serve(@server.accept) }
  end

  def close
    @thread.join(5)
    @server.close
  end

  private

  def serve(sock)
    sock.write("220 fake ESMTP\r\n")
    while (line = sock.gets)
      case line
      when /\AEHLO/i then sock.write("250-fake\r\n250-AUTH PLAIN LOGIN\r\n250 8BITMIME\r\n")
      when /\AAUTH/i then sock.write("235 2.7.0 ok\r\n")
      when /\AMAIL FROM/i, /\ARCPT TO/i then sock.write("250 ok\r\n")
      when /\ADATA/i
        sock.write("354 go ahead\r\n")
        data = +''
        while (l = sock.gets)
          break if l == ".\r\n"

          data << l
        end
        @messages << data
        case @after_data
        when :accept then sock.write("250 2.0.0 Ok: queued as ABC123\r\n")
        when :reject then sock.write("554 5.7.1 message rejected\r\n")
        when :drop then break
        end
      when /\AQUIT/i
        sock.write("221 bye\r\n")
        break
      else sock.write("502 unsupported\r\n")
      end
    end
  ensure
    sock.close
  end
end

puts "\nInput shape: addresses and custom headers"
reset!
status, body, = post(TEST_HANDLER, crm_payload('to' => "a@example.com\r\nBcc: evil@example.net"))
check.call('CRLF in a recipient is 400', [status, body['field']], [400, 'to'])
status, body, = post(TEST_HANDLER, crm_payload('to' => ['ok@example.com', 'not-an-address']))
check.call('malformed recipient is 400', [status, body['field']], [400, 'to'])
status, body, = post(TEST_HANDLER, crm_payload('to' => [123]))
check.call('non-string recipient is 400, not 500', status, 400)
status, body, = post(TEST_HANDLER, crm_payload('cc' => { 'x' => 1 }))
check.call('object as cc is 400', status, 400)
status, body, = post(TEST_HANDLER, crm_payload('replyTo' => 'Boss <boss@example.com>'))
check.call('display-name form in replyTo is 400', status, 400)
status, body, = post(TEST_HANDLER, crm_payload('to' => (1..101).map { |i| "u#{i}@example.com" }))
check.call('101 recipients is 400', status, 400)
status, body, = post(TEST_HANDLER, crm_payload('headers' => { 'Bcc' => 'evil@example.net' }))
check.call('Bcc via headers is refused', [status, body['field']], [400, 'headers'])
status, body, = post(TEST_HANDLER, crm_payload('headers' => { 'Content-Type' => 'text/html' }))
check.call('Content-Type via headers is refused', status, 400)
status, body, = post(TEST_HANDLER, crm_payload('headers' => { 'X-Campaign' => "q4\r\nBcc: evil@example.net", 'List-Unsubscribe' => '<mailto:u@example.com>' }))
check.call('X-* and List-* headers are accepted', status, 200)
m = reparse(deliveries.last)
check.call('CRLF stripped from the header value', m['X-Campaign'].value, 'q4  Bcc: evil@example.net')
check.call('no Bcc was injected', m.bcc, nil)
check.call('List-Unsubscribe survives', m['List-Unsubscribe'].value, '<mailto:u@example.com>')
status, body, = post(TEST_HANDLER, crm_payload('headers' => ['X-A: 1']))
check.call('array as headers is 400', status, 400)
reset!
status, body, = post(TEST_HANDLER, crm_payload('subject' => "Hi\r\nBcc: evil@example.net", 'to' => ' client@example.com '))
check.call('subject with CRLF still sends', status, 200)
m = reparse(deliveries.last)
check.call('subject CRLF was flattened', m.subject, 'Hi  Bcc: evil@example.net')
check.call('recipient whitespace is trimmed', m.to, ['client@example.com'])

puts "\nReal SMTP path (fake server on 127.0.0.1)"
smtp_handler = Handlers::MailHandler.new(
  attempts:  Services::SendAttemptStore.new(ttl_hours: 24, database: DB),
  validator: Services::AttachmentValidator.new
)
{ accept: [200, 'sent'], reject: [500, 'failed'], drop: [504, 'unknown'] }.each do |mode, expected|
  reset!
  server = FakeSMTPServer.new(mode)
  status, body, = post(smtp_handler, crm_payload, {}, client: client_row(port: server.port))
  server.close
  check.call("server #{mode}s after DATA -> #{expected.last}", [status, body['status']], expected)
  check.call("server #{mode}: the message reached DATA once", server.messages.size, 1)
  if mode == :accept
    check.call('smtpResponse is the 250 reply', body['smtpResponse'], '250 2.0.0 Ok: queued as ABC123')
    wire = Mail.read_from_string(server.messages.first)
    check.call('the wire message carries the PDF', wire.attachments.map(&:filename), [CYRILLIC_NAME])
  end
end

reset!
server = TCPServer.new('127.0.0.1', 0)
closed_port = server.addr[1]
server.close
status, body, = post(smtp_handler, crm_payload, {}, client: client_row(port: closed_port))
check.call('nothing listening -> failed', [status, body['status']], [500, 'failed'])

Assertions.report('mail send')
