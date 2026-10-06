# frozen_string_literal: true

require 'digest'

module Services
  # Validates and decodes the `attachments` array of POST /send.
  #
  # Pure: no database, no gems — only stdlib `digest`. Base64 is decoded with
  # `unpack1('m0')`, which is strict (RFC 4648, no line breaks, padding
  # required) and raises ArgumentError on anything else.
  #
  # The decoded bytes live only in the returned Attachment structs for as long
  # as the request needs them. Anything that is persisted or logged goes
  # through Attachment#metadata, which never carries content.
  class AttachmentValidator
    MIB = 1024 * 1024

    DEFAULT_MAX_COUNT       = 5
    DEFAULT_MAX_BYTES       = 10 * MIB
    DEFAULT_MAX_TOTAL_BYTES = 20 * MIB
    DEFAULT_ALLOWED_TYPES   = %w[application/pdf].freeze

    # Filenames are cut to this many characters (extension kept).
    MAX_FILENAME_CHARS = 180

    # Magic prefixes checked for types whose bytes we can cheaply recognise.
    MAGIC = {
      'application/pdf' => '%PDF-'.b
    }.freeze

    # A validation failure. `status` is the HTTP status the handler answers
    # with, `field` names the offending input (e.g. attachments[0].contentType).
    class Error < StandardError
      attr_reader :status, :field

      def initialize(message, status: 400, field: nil)
        super(message)
        @status = status
        @field  = field
      end
    end

    Attachment = Struct.new(:filename, :content_type, :content, :size, :sha256, keyword_init: true) do
      # Everything about the attachment except its bytes. Safe to log and store.
      def metadata
        { filename: filename, contentType: content_type, size: size, sha256: sha256 }
      end
    end

    attr_reader :max_count, :max_bytes, :max_total_bytes, :allowed_types

    def self.from_env(env = ENV)
      new(
        max_count:       positive_int(env['MAIL_ATTACHMENTS_MAX_COUNT'], DEFAULT_MAX_COUNT),
        max_bytes:       positive_int(env['MAIL_ATTACHMENT_MAX_BYTES'], DEFAULT_MAX_BYTES),
        max_total_bytes: positive_int(env['MAIL_ATTACHMENTS_MAX_TOTAL_BYTES'], DEFAULT_MAX_TOTAL_BYTES),
        allowed_types:   parse_types(env['MAIL_ATTACHMENT_ALLOWED_TYPES'])
      )
    end

    def self.positive_int(raw, default)
      value = Integer(raw.to_s.strip, 10)
      value.positive? ? value : default
    rescue ArgumentError, TypeError
      default
    end

    def self.parse_types(raw)
      types = raw.to_s.split(',').map { |t| t.strip.downcase }.reject(&:empty?)
      types.empty? ? DEFAULT_ALLOWED_TYPES : types.uniq.freeze
    end

    def initialize(max_count: DEFAULT_MAX_COUNT, max_bytes: DEFAULT_MAX_BYTES,
                   max_total_bytes: DEFAULT_MAX_TOTAL_BYTES, allowed_types: DEFAULT_ALLOWED_TYPES)
      @max_count       = max_count
      @max_bytes       = max_bytes
      @max_total_bytes = max_total_bytes
      @allowed_types   = allowed_types
    end

    # Largest JSON body POST /send should accept: the base64 expansion of the
    # total attachment budget plus 1 MiB for the rest of the message.
    def max_request_bytes
      ((max_total_bytes + 2) / 3 * 4) + MIB
    end

    # @param raw [nil, Array] the `attachments` value from the request JSON
    # @return [Array<Attachment>]
    # @raise [Error]
    def validate(raw)
      return [] if raw.nil?
      raise Error.new('attachments must be an array', field: 'attachments') unless raw.is_a?(Array)

      if raw.length > max_count
        raise Error.new("Too many attachments: #{raw.length} (max #{max_count})", status: 413, field: 'attachments')
      end

      total = 0
      raw.each_with_index.map do |item, index|
        attachment = validate_one(item, "attachments[#{index}]", total)
        total += attachment.size
        attachment
      end
    end

    # Filename cleanup: keeps UTF-8 (Cyrillic included), drops control and
    # format characters (incl. bidi overrides), replaces path separators and
    # characters that are illegal in Windows filenames, and strips leading dots.
    # Returns '' when nothing usable is left.
    def self.sanitize_filename(raw)
      name = raw.to_s.dup.force_encoding(Encoding::UTF_8)
      return '' unless name.valid_encoding?

      name = name.unicode_normalize(:nfc)
      name = name.gsub(/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/, '')
      name = name.tr('/\\', '__')
      name = name.gsub(/[<>:"|?*]/, '_')
      name = name.gsub(/\s+/, ' ').strip
      name = name.sub(/\A[.\s]+/, '')
      truncate_filename(name)
    end

    def self.truncate_filename(name)
      return name if name.length <= MAX_FILENAME_CHARS

      ext = File.extname(name)
      ext = '' if ext.length > 16
      stem = name[0, MAX_FILENAME_CHARS - ext.length].rstrip
      "#{stem}#{ext}"
    end

    private

    def validate_one(item, field, total_so_far)
      raise Error.new("#{field} must be an object", field: field) unless item.is_a?(Hash)

      filename     = validate_filename(item['filename'], "#{field}.filename")
      content_type = validate_content_type(item['contentType'], "#{field}.contentType")
      content      = decode(item['contentBase64'], "#{field}.contentBase64", total_so_far)

      magic = MAGIC[content_type]
      if magic && !content.start_with?(magic)
        raise Error.new("#{field}.contentBase64 does not contain a #{content_type} document",
                        field: "#{field}.contentBase64")
      end

      Attachment.new(
        filename:     filename,
        content_type: content_type,
        content:      content,
        size:         content.bytesize,
        sha256:       Digest::SHA256.hexdigest(content)
      )
    end

    def validate_filename(raw, field)
      unless raw.is_a?(String) && !raw.strip.empty?
        raise Error.new("#{field} is required", field: field)
      end

      name = self.class.sanitize_filename(raw)
      raise Error.new("#{field} is not a usable filename", field: field) if name.empty?

      name
    end

    def validate_content_type(raw, field)
      raise Error.new("#{field} is required", field: field) unless raw.is_a?(String) && !raw.strip.empty?

      type = raw.split(';').first.to_s.strip.downcase
      unless allowed_types.include?(type)
        raise Error.new("#{field} '#{type}' is not allowed (allowed: #{allowed_types.join(', ')})",
                        status: 415, field: field)
      end

      type
    end

    def decode(raw, field, total_so_far)
      raise Error.new("#{field} is required", field: field) unless raw.is_a?(String) && !raw.empty?

      # Reject oversize input before allocating the decoded copy.
      estimated = raw.bytesize / 4 * 3
      check_size(estimated - 2, field, total_so_far)

      bytes = begin
        raw.unpack1('m0')
      rescue ArgumentError
        raise Error.new("#{field} is not valid base64", field: field)
      end

      raise Error.new("#{field} decodes to an empty file", field: field) if bytes.empty?

      check_size(bytes.bytesize, field, total_so_far)
      bytes
    end

    def check_size(size, field, total_so_far)
      if size > max_bytes
        raise Error.new("#{field} exceeds the per-file limit of #{max_bytes} bytes", status: 413, field: field)
      end
      return unless total_so_far + size > max_total_bytes

      raise Error.new("attachments exceed the total limit of #{max_total_bytes} bytes", status: 413, field: field)
    end
  end
end
