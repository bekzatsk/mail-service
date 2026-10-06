# frozen_string_literal: true

# What POST /send accepts as an attachment.
#
# Pure: no bundle, no gems, no database — the validator only needs stdlib.
#
#   ruby test/attachment_validation_test.rb

require_relative 'support/assertions'
require_relative '../app/services/attachment_validator'

Validator = Services::AttachmentValidator

PDF = "%PDF-1.4\n%\xE2\xE3\xCF\xD3\n1 0 obj << >> endobj\ntrailer << >>\n%%EOF\n".b
def b64(bytes) = [bytes].pack('m0')

def pdf(overrides = {})
  { 'filename' => 'КП_REQ-1042_v3.pdf', 'contentType' => 'application/pdf', 'contentBase64' => b64(PDF) }
    .merge(overrides)
end

# The error a call raises, as [status, field], or :ok when it passes.
def outcome(validator, raw)
  validator.validate(raw)
  :ok
rescue Validator::Error => e
  [e.status, e.field]
end

v = Validator.new
check = Assertions.method(:check)

puts 'Absent attachments change nothing'
check.call('nil -> []', v.validate(nil), [])
check.call('[] -> []', v.validate([]), [])

puts "\nA valid PDF"
a = v.validate([pdf]).first
check.call('filename keeps Cyrillic', a.filename, 'КП_REQ-1042_v3.pdf')
check.call('content type', a.content_type, 'application/pdf')
check.call('content is the decoded bytes', a.content, PDF)
check.call('size is the decoded size', a.size, PDF.bytesize)
check.call('sha256 of the decoded bytes', a.sha256, Digest::SHA256.hexdigest(PDF))
check.call('metadata carries no content', a.metadata.keys, %i[filename contentType size sha256])
check.call('content type parameters are ignored',
           v.validate([pdf('contentType' => 'Application/PDF; name=x.pdf')]).first.content_type, 'application/pdf')

puts "\nShape"
check.call('attachments not an array -> 400', outcome(v, { 'a' => 1 }), [400, 'attachments'])
check.call('attachments a string -> 400', outcome(v, 'x'), [400, 'attachments'])
check.call('item not an object -> 400', outcome(v, ['x']), [400, 'attachments[0]'])
check.call('6 attachments with max 5 -> 413', outcome(v, Array.new(6) { pdf }), [413, 'attachments'])
check.call('5 attachments with max 5 -> ok', outcome(v, Array.new(5) { pdf }), :ok)

puts "\nFilename"
check.call('missing -> 400', outcome(v, [pdf('filename' => nil)]), [400, 'attachments[0].filename'])
check.call('blank -> 400', outcome(v, [pdf('filename' => '   ')]), [400, 'attachments[0].filename'])
check.call('not a string -> 400', outcome(v, [pdf('filename' => 42)]), [400, 'attachments[0].filename'])
check.call('only dots and controls -> 400', outcome(v, [pdf('filename' => "..\u0000\u0007")]),
           [400, 'attachments[0].filename'])
check.call('path separators become _',
           Validator.sanitize_filename('../../etc/passwd.pdf'), '_.._etc_passwd.pdf')
check.call('backslashes become _', Validator.sanitize_filename('C:\\docs\\КП.pdf'), 'C__docs_КП.pdf')
check.call('control chars and CR/LF are dropped',
           Validator.sanitize_filename("КП\r\nBcc: x@y.z\u0000.pdf"), 'КПBcc_ x@y.z.pdf')
check.call('bidi override is dropped', Validator.sanitize_filename("invoice\u202Efdp.exe"), 'invoicefdp.exe')
check.call('quotes cannot break the header', Validator.sanitize_filename('a"b.pdf'), 'a_b.pdf')
check.call('invalid UTF-8 -> empty', Validator.sanitize_filename("\xFF\xFE.pdf".b), '')
long = "#{'Я' * 300}.pdf"
check.call('long names are cut, extension kept', Validator.sanitize_filename(long).end_with?('.pdf'), true)
check.call('long names are cut to the limit', Validator.sanitize_filename(long).length, Validator::MAX_FILENAME_CHARS)

puts "\nContent type"
check.call('missing -> 400', outcome(v, [pdf('contentType' => nil)]), [400, 'attachments[0].contentType'])
check.call('image/png is not allowed -> 415', outcome(v, [pdf('contentType' => 'image/png')]),
           [415, 'attachments[0].contentType'])
check.call('application/octet-stream -> 415', outcome(v, [pdf('contentType' => 'application/octet-stream')]),
           [415, 'attachments[0].contentType'])

puts "\nBase64"
field = 'attachments[0].contentBase64'
check.call('missing -> 400', outcome(v, [pdf('contentBase64' => nil)]), [400, field])
check.call('empty -> 400', outcome(v, [pdf('contentBase64' => '')]), [400, field])
check.call('garbage -> 400', outcome(v, [pdf('contentBase64' => 'not base64 !!')]), [400, field])
check.call('missing padding -> 400', outcome(v, [pdf('contentBase64' => b64(PDF).delete('='))]), [400, field])
check.call('line-wrapped (MIME style) -> 400',
           outcome(v, [pdf('contentBase64' => [PDF * 3].pack('m'))]), [400, field])
check.call('url-safe alphabet -> 400',
           outcome(v, [pdf('contentBase64' => b64("%PDF-\xFB\xFF".b).tr('+/', '-_'))]), [400, field])

puts "\nPDF magic bytes"
check.call('non-PDF bytes declared as PDF -> 400', outcome(v, [pdf('contentBase64' => b64('hello world'))]),
           [400, field])
check.call('PNG bytes declared as PDF -> 400',
           outcome(v, [pdf('contentBase64' => b64("\x89PNG\r\n\x1A\n".b))]), [400, field])
check.call('%PDF- must be at the very start', outcome(v, [pdf('contentBase64' => b64(" #{PDF}"))]), [400, field])

puts "\nSize limits"
small = Validator.new(max_bytes: 100, max_total_bytes: 150)
fits = "%PDF-#{'x' * 90}".b
too_big = "%PDF-#{'x' * 200}".b
check.call('file at the limit -> ok', outcome(small, [pdf('contentBase64' => b64(fits))]), :ok)
check.call('file over the per-file limit -> 413', outcome(small, [pdf('contentBase64' => b64(too_big))]),
           [413, field])
check.call('two files over the total -> 413',
           outcome(small, [pdf('contentBase64' => b64(fits)), pdf('contentBase64' => b64(fits))]),
           [413, 'attachments[1].contentBase64'])
huge = Validator.new(max_bytes: 1024, max_total_bytes: 4096)
check.call('oversize input is rejected before decoding',
           outcome(huge, [pdf('contentBase64' => '!' * 10_000)]), [413, field])
check.call('max request size covers the base64 of the total budget',
           Validator.new.max_request_bytes >= (Validator::DEFAULT_MAX_TOTAL_BYTES * 4 / 3), true)

puts "\nConfiguration from ENV"
env = Validator.from_env(
  'MAIL_ATTACHMENTS_MAX_COUNT' => '2',
  'MAIL_ATTACHMENT_MAX_BYTES' => '2048',
  'MAIL_ATTACHMENTS_MAX_TOTAL_BYTES' => '4096',
  'MAIL_ATTACHMENT_ALLOWED_TYPES' => 'application/pdf, Image/PNG'
)
check.call('max count', env.max_count, 2)
check.call('max bytes', env.max_bytes, 2048)
check.call('max total bytes', env.max_total_bytes, 4096)
check.call('allowed types are normalised', env.allowed_types, %w[application/pdf image/png])
defaults = Validator.from_env({})
check.call('default max count', defaults.max_count, 5)
check.call('default per-file limit is 10 MiB', defaults.max_bytes, 10 * 1024 * 1024)
check.call('default total limit is 20 MiB', defaults.max_total_bytes, 20 * 1024 * 1024)
check.call('default allowlist is PDF only', defaults.allowed_types, %w[application/pdf])
check.call('junk values fall back to defaults',
           Validator.from_env('MAIL_ATTACHMENTS_MAX_COUNT' => 'lots', 'MAIL_ATTACHMENT_MAX_BYTES' => '-1').max_count, 5)
png = "\x89PNG\r\n\x1A\n".b
check.call('a configured non-PDF type skips the PDF check',
           outcome(env, [pdf('contentType' => 'image/png', 'contentBase64' => b64(png))]), :ok)

Assertions.report('attachment validation')
