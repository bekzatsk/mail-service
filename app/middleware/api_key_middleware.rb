# frozen_string_literal: true

require_relative '../services/database'

module Middleware
  class ApiKeyMiddleware
    # Routes that require the MASTER_API_KEY
    MASTER_ROUTES = [
      { method: 'POST', path: '/organizations' },
      { method: 'POST', path: '/config' },
      { method: 'POST', path: '/config/test' }
    ].freeze

    # Routes that are fully public (no key needed)
    PUBLIC_ROUTES = [
      { method: 'GET', prefix: '/organizations' }
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
      PUBLIC_ROUTES.any? do |route|
        method == route[:method] && path.start_with?(route[:prefix])
      end
    end

    def master_route?(method, path)
      MASTER_ROUTES.any? do |route|
        method == route[:method] && path == route[:path]
      end
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

    def authenticate_client(api_key, env)
      result = Services::Database.query(
        'SELECT c.*, o.name AS organization_name, o.slug AS organization_slug
         FROM clients c
         JOIN organizations o ON o.id = c.organization_id
         WHERE c.api_key = ?', [api_key]
      )
      client = result.first

      unless client
        return json_error('Invalid API key', 403)
      end

      env['mail_service.client'] = client
      @app.call(env)
    end

    # Constant-time string comparison to prevent timing attacks
    def secure_compare(a, b)
      return false unless a.bytesize == b.bytesize

      l = a.unpack('C*')
      r = b.unpack('C*')
      result = 0
      l.zip(r) { |x, y| result |= x ^ y }
      result.zero?
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
