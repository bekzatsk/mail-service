# frozen_string_literal: true

module Middleware
  # Response headers that hold for every response, API and console alike.
  #
  # The console keeps the master key in web storage, so a script injection
  # there would hand over every client key. The CSP below is what makes that
  # injection inert: scripts and styles only from this origin, no inline
  # script, no framing, no form posts elsewhere. API responses are additionally
  # marked no-store so a browser never caches a page that carries an API key.
  class SecurityHeaders
    CSP = [
      "default-src 'none'",
      "script-src 'self'",
      "style-src 'self'",
      "img-src 'self' data:",
      "font-src 'self'",
      "connect-src 'self'",
      "base-uri 'none'",
      "form-action 'self'",
      "frame-ancestors 'none'"
    ].join('; ').freeze

    HSTS = 'max-age=31536000; includeSubDomains'

    def initialize(app)
      @app = app
    end

    def call(env)
      status, headers, body = @app.call(env)
      headers = headers.dup

      headers['X-Content-Type-Options'] ||= 'nosniff'
      headers['X-Frame-Options']        ||= 'DENY'
      headers['Referrer-Policy']        ||= 'no-referrer'
      headers['Content-Security-Policy'] ||= CSP
      headers['Permissions-Policy']     ||= 'camera=(), microphone=(), geolocation=()'
      headers['Strict-Transport-Security'] ||= HSTS if https?(env)

      # Everything that is not a console asset is API output.
      unless env['PATH_INFO'].to_s.start_with?('/ui', '/favicon')
        headers['Cache-Control'] ||= 'no-store'
      end

      [status, headers, body]
    end

    private

    def https?(env)
      env['rack.url_scheme'] == 'https' ||
        env['HTTP_X_FORWARDED_PROTO'].to_s.split(',').first.to_s.strip == 'https'
    end
  end
end
