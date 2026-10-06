# frozen_string_literal: true

require 'json'

module Middleware
  # Refuses request bodies larger than an endpoint could ever need.
  #
  # Every handler reads the whole body into memory before parsing it, so
  # without a cap one client can take a worker down with a single large POST.
  # /send carries attachments and keeps its own, larger limit in MailHandler;
  # everything else is a small JSON document.
  class BodyLimit
    DEFAULT_LIMIT = 1024 * 1024 # 1 MiB

    def initialize(app, limit: nil, exempt_prefixes: ['/send'])
      @app = app
      @limit = limit || positive_int(ENV['MAX_REQUEST_BYTES'], DEFAULT_LIMIT)
      @exempt_prefixes = exempt_prefixes
    end

    def call(env)
      length = env['CONTENT_LENGTH'].to_s
      if !length.empty? && length.to_i > @limit && !exempt?(env['PATH_INFO'].to_s)
        body = JSON.generate(error: 'Request body too large', details: "limit is #{@limit} bytes")
        return [413, { 'Content-Type' => 'application/json' }, [body]]
      end

      @app.call(env)
    end

    private

    def exempt?(path)
      @exempt_prefixes.any? { |prefix| path == prefix || path.start_with?("#{prefix}/") }
    end

    def positive_int(raw, default)
      value = Integer(raw.to_s.strip, 10)
      value.positive? ? value : default
    rescue ArgumentError, TypeError
      default
    end
  end
end
