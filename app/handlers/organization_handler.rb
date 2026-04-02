# frozen_string_literal: true

require_relative '../services/database'

module Handlers
  class OrganizationHandler
    # POST /organizations
    # Create a new organization.
    def create(request)
      data = parse_json(request)

      if data['name'].nil? || data['name'].to_s.strip.empty?
        return json_response({ error: 'Missing required field: name' }, 400)
      end

      name = data['name'].strip
      slug = data['slug']&.strip || name.downcase.gsub(/[^a-z0-9]+/, '-').gsub(/^-|-$/, '')

      # Check slug uniqueness
      existing = Services::Database.query('SELECT id FROM organizations WHERE slug = ?', [slug])
      if existing.first
        return json_response({ error: "Organization slug '#{slug}' already exists" }, 409)
      end

      Services::Database.query(
        'INSERT INTO organizations (name, slug) VALUES (?, ?)',
        [name, slug]
      )

      # Fetch the created record
      result = Services::Database.query('SELECT * FROM organizations WHERE slug = ?', [slug])
      org = result.first

      json_response({
        organization: {
          id:         org['id'],
          name:       org['name'],
          slug:       org['slug'],
          created_at: org['created_at']&.to_s
        },
        message: 'Organization created successfully'
      }, 201)
    end

    # GET /organizations
    # List all organizations.
    def list
      results = Services::Database.query(
        'SELECT id, name, slug, created_at FROM organizations ORDER BY created_at DESC'
      )

      orgs = results.map do |row|
        {
          id:         row['id'],
          name:       row['name'],
          slug:       row['slug'],
          created_at: row['created_at']&.to_s
        }
      end

      json_response({ organizations: orgs })
    end

    # GET /organizations/:id
    # Get a single organization with its clients count.
    def show(org_id)
      result = Services::Database.query('SELECT * FROM organizations WHERE id = ?', [org_id])
      org = result.first

      unless org
        return json_response({ error: 'Organization not found' }, 404)
      end

      clients_result = Services::Database.query(
        'SELECT COUNT(*) AS cnt FROM clients WHERE organization_id = ?', [org_id]
      )
      clients_count = clients_result.first['cnt']

      json_response({
        organization: {
          id:            org['id'],
          name:          org['name'],
          slug:          org['slug'],
          clients_count: clients_count,
          created_at:    org['created_at']&.to_s
        }
      })
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
