# frozen_string_literal: true

require 'securerandom'
require_relative '../services/database'
require_relative '../services/encryption_service'

module Handlers
  class ConfigHandler
    def initialize
      @encryption = Services::EncryptionService.new
    end

    # POST /config
    # Register a new client SMTP configuration, return generated API key.
    def call(request)
      data = parse_json(request)

      # Validate required fields
      required = %w[organization_id smtp_host smtp_port smtp_user smtp_pass from_address]
      missing  = required.select { |f| data[f].nil? || data[f].to_s.empty? }

      unless missing.empty?
        return json_response(
          { error: "Missing required fields: #{missing.join(', ')}" }, 400
        )
      end

      # Verify organization exists
      org_result = Services::Database.query(
        'SELECT id FROM organizations WHERE id = ?', [data['organization_id'].to_i]
      )
      unless org_result.first
        return json_response({ error: 'Organization not found' }, 404)
      end

      # Generate secure API key
      api_key = SecureRandom.hex(32)

      # Encrypt SMTP password
      encrypted_pass = @encryption.encrypt(data['smtp_pass'])

      # Persist to database
      Services::Database.query(
        'INSERT INTO clients (organization_id, api_key, smtp_host, smtp_port, smtp_user, smtp_pass, from_address) VALUES (?, ?, ?, ?, ?, ?, ?)',
        [data['organization_id'].to_i, api_key, data['smtp_host'], data['smtp_port'].to_i, data['smtp_user'], encrypted_pass, data['from_address']]
      )

      json_response({ api_key: api_key, message: 'Client registered successfully' }, 201)
    end

    private

    def parse_json(request)
      body = request.body.read
      request.body.rewind
      JSON.parse(body)
    rescue JSON::ParserError
      {}
    end

    def json_response(payload, status = 200)
      [status, { 'Content-Type' => 'application/json' }, [JSON.generate(payload)]]
    end
  end
end
