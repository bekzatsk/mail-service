# frozen_string_literal: true

require_relative '../services/database'
require_relative '../services/secure_compare'

module Middleware
  class ApiKeyMiddleware
    # Routes that require the MASTER_API_KEY
    MASTER_ROUTES = [
      { method: 'POST', path: '/organizations' },
      { method: 'POST', path: '/config' },
      { method: 'POST', path: '/config/test' }
    ].freeze

    # Route prefixes that require the MASTER_API_KEY (admin UI backend, and
    # organization reads — the tenant list is not something a client may enumerate)
    MASTER_PREFIXES = [
      { method: 'GET',    prefix: '/admin' },
      { method: 'POST',   prefix: '/admin' },
      { method: 'PATCH',  prefix: '/admin' },
      { method: 'DELETE', prefix: '/admin' },
      { method: 'GET',    prefix: '/organizations' }
    ].freeze

    # Routes that are fully public (no key needed).
    # Only the admin UI's own static assets — the panel holds no data, and every
    # request it makes still carries the master key.
    PUBLIC_ROUTES = [
      { method: 'GET', prefix: '/ui' },
      { method: 'GET', prefix: '/favicon' },
      # Telegram cannot send our X-Api-Key. These deliveries authenticate with
      # the per-bot X-Telegram-Bot-Api-Secret-Token header instead, compared in
      # TelegramHandler#receive_webhook. Unauthenticated here on purpose.
      { method: 'POST', prefix: '/telegram/webhook/' }
    ].freeze

    # Exact paths that are public (the / -> /ui redirect)
    PUBLIC_PATHS = [
      { method: 'GET', path: '/' }
    ].freeze

    def initialize(app)
      @app = app
      @master_key = ENV.fetch('MASTER_API_KEY', '')
    end

    def call(env)
      request = Rack::Request.new(env)
      method  = request.request_method
      path    = request.path

      # Public routes — no auth required
      if public_route?(method, path)
        return @app.call(env)
      end

      api_key = env['HTTP_X_API_KEY']

      if api_key.nil? || api_key.empty?
        return json_error('Missing X-Api-Key header', 401)
      end

      # Master routes — require MASTER_API_KEY
      if master_route?(method, path)
        return authenticate_master(api_key, env)
      end

      # All other routes — require client API key
      authenticate_client(api_key, env)
    end

    private

    def public_route?(method, path)
      PUBLIC_PATHS.any? { |r| method == r[:method] && path == r[:path] } ||
        PUBLIC_ROUTES.any? do |route|
          method == route[:method] && path.start_with?(route[:prefix])
        end
    end

    def master_route?(method, path)
      MASTER_ROUTES.any? { |r| method == r[:method] && path == r[:path] } ||
        MASTER_PREFIXES.any? { |r| method == r[:method] && path.start_with?(r[:prefix]) }
    end

    def authenticate_master(api_key, env)
      if @master_key.empty?
        return json_error('MASTER_API_KEY is not configured on the server', 500)
      end

      unless secure_compare(api_key, @master_key)
        return json_error('Invalid master API key', 403)
      end

      @app.call(env)
    end

    # Client keys are SecureRandom.hex(32): anything else cannot be one, and
    # is answered without a database round-trip.
    CLIENT_KEY_FORMAT = /\A[0-9a-f]{64}\z/

    def authenticate_client(api_key, env)
      return json_error('Invalid API key', 403) unless api_key.match?(CLIENT_KEY_FORMAT)

      client = begin
        Services::Database.query(
          'SELECT c.*, o.name AS organization_name, o.slug AS organization_slug
           FROM clients c
           JOIN organizations o ON o.id = c.organization_id
           WHERE c.api_key = ?', [api_key]
        ).first
      rescue StandardError => e
        # This middleware sits outside the Sinatra error handler, so a database
        # failure here would otherwise surface as the server's raw 500 page.
        warn "[auth] client lookup failed: #{e.class}: #{e.message}"
        return json_error('Service unavailable', 503)
      end

      unless client
        return json_error('Invalid API key', 403)
      end

      env['mail_service.client'] = client
      @app.call(env)
    end

    def secure_compare(a, b)
      Services::SecureCompare.call(a, b)
    end

    def json_error(message, status)
      body = JSON.generate(error: message)
      [
        status,
        { 'Content-Type' => 'application/json' },
        [body]
      ]
    end
  end
end
