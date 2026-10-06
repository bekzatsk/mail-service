# frozen_string_literal: true

require 'json'
require 'securerandom'
require_relative '../services/database'
require_relative '../services/encryption_service'
require_relative '../services/smtp_test_service'

module Handlers
  # Master-key protected endpoints backing the admin UI.
  # Everything here is mounted under /admin and requires MASTER_API_KEY.
  class AdminHandler
    MAX_LIMIT     = 500
    DEFAULT_LIMIT = 100

    def initialize
      @encryption = Services::EncryptionService.new
      @smtp_test  = Services::SmtpTestService.new
    end

    # ── Dashboard ──────────────────────────────────────────────────────

    # GET /admin/stats
    def stats
      json({
        organizations: scalar('SELECT COUNT(*) AS c FROM organizations'),
        clients:       scalar('SELECT COUNT(*) AS c FROM clients'),
        mail: {
          total:  scalar('SELECT COUNT(*) AS c FROM mail_logs'),
          sent:   scalar("SELECT COUNT(*) AS c FROM mail_logs WHERE status = 'sent'"),
          failed: scalar("SELECT COUNT(*) AS c FROM mail_logs WHERE status = 'failed'"),
          last24h: scalar('SELECT COUNT(*) AS c FROM mail_logs WHERE created_at >= NOW() - INTERVAL 1 DAY')
        },
        telegram: {
          bots:         scalar('SELECT COUNT(*) AS c FROM client_telegram_bots'),
          enabled_bots: scalar('SELECT COUNT(*) AS c FROM client_telegram_bots WHERE is_enabled = TRUE'),
          messages:     scalar('SELECT COUNT(*) AS c FROM telegram_messages')
        }
      })
    end

    # ── Organizations ──────────────────────────────────────────────────

    # GET /admin/organizations
    def list_organizations
      rows = Services::Database.query(
        'SELECT o.id, o.name, o.slug, o.created_at,
                (SELECT COUNT(*) FROM clients c WHERE c.organization_id = o.id) AS clients_count,
                (SELECT COUNT(*) FROM mail_logs ml
                   JOIN clients c2 ON c2.id = ml.client_id
                  WHERE c2.organization_id = o.id) AS logs_count
           FROM organizations o
          ORDER BY o.created_at DESC'
      )

      json({ organizations: rows.map { |r| serialize_organization(r) } })
    end

    # PATCH /admin/organizations/:id
    def update_organization(request, org_id)
      org = find_organization(org_id)
      return error('Organization not found', 404) unless org

      data = parse_json(request)
      sets = []
      values = []

      if data.key?('name')
        return error('name cannot be empty', 400) if blank?(data['name'])

        sets << 'name = ?'
        values << data['name'].to_s.strip
      end

      if data.key?('slug')
        slug = data['slug'].to_s.strip
        return error('slug cannot be empty', 400) if slug.empty?
        return error('Invalid slug (a-z, 0-9, dashes)', 400) unless slug =~ /\A[a-z0-9-]+\z/

        taken = Services::Database.query(
          'SELECT id FROM organizations WHERE slug = ? AND id != ?', [slug, org_id]
        ).first
        return error("Organization slug '#{slug}' already exists", 409) if taken

        sets << 'slug = ?'
        values << slug
      end

      return error('No fields to update', 400) if sets.empty?

      values << org_id
      Services::Database.query("UPDATE organizations SET #{sets.join(', ')} WHERE id = ?", values)

      json({ organization: serialize_organization(find_organization(org_id)) })
    end

    # DELETE /admin/organizations/:id
    # Cascades to clients and mail_logs via foreign keys.
    def delete_organization(org_id)
      return error('Organization not found', 404) unless find_organization(org_id)

      Services::Database.query('DELETE FROM organizations WHERE id = ?', [org_id])
      json({ message: 'Organization deleted' })
    end

    # ── Clients ────────────────────────────────────────────────────────

    # GET /admin/clients[?organization_id=]
    def list_clients(request)
      org_id = request.params['organization_id']

      sql = <<~SQL
        SELECT c.*, o.name AS organization_name, o.slug AS organization_slug,
               (SELECT COUNT(*) FROM mail_logs ml WHERE ml.client_id = c.id) AS logs_count,
               (SELECT COUNT(*) FROM client_telegram_bots b WHERE b.client_id = c.id) AS bots_count
          FROM clients c
          JOIN organizations o ON o.id = c.organization_id
      SQL

      rows =
        if org_id && !org_id.to_s.empty?
          Services::Database.query("#{sql} WHERE c.organization_id = ? ORDER BY c.created_at DESC", [org_id.to_i])
        else
          Services::Database.query("#{sql} ORDER BY c.created_at DESC")
        end

      json({ clients: rows.map { |r| serialize_client(r) } })
    end

    # GET /admin/clients/:id
    def show_client(client_id)
      row = load_client(client_id)
      return error('Client not found', 404) unless row

      json({ client: serialize_client(row) })
    end

    # PATCH /admin/clients/:id
    def update_client(request, client_id)
      return error('Client not found', 404) unless load_client(client_id)

      data = parse_json(request)
      sets = []
      values = []

      %w[smtp_host smtp_user from_address].each do |field|
        next unless data.key?(field)
        return error("#{field} cannot be empty", 400) if blank?(data[field])

        sets << "#{field} = ?"
        values << data[field].to_s.strip
      end

      if data.key?('smtp_port')
        port = data['smtp_port'].to_i
        return error('Invalid smtp_port', 400) unless port.positive? && port < 65_536

        sets << 'smtp_port = ?'
        values << port
      end

      # Password is optional on update — only re-encrypted when actually supplied.
      unless blank?(data['smtp_pass'])
        sets << 'smtp_pass = ?'
        values << @encryption.encrypt(data['smtp_pass'])
      end

      return error('No fields to update', 400) if sets.empty?

      values << client_id
      Services::Database.query("UPDATE clients SET #{sets.join(', ')} WHERE id = ?", values)

      json({ client: serialize_client(load_client(client_id)) })
    end

    # POST /admin/clients/:id/rotate-key
    def rotate_client_key(client_id)
      return error('Client not found', 404) unless load_client(client_id)

      api_key = SecureRandom.hex(32)
      Services::Database.query('UPDATE clients SET api_key = ? WHERE id = ?', [api_key, client_id])

      json({ api_key: api_key, message: 'API key rotated — the previous key no longer works' })
    end

    # POST /admin/clients/:id/test
    # Tests the SMTP credentials already stored for this client.
    def test_client(client_id)
      row = load_client(client_id)
      return error('Client not found', 404) unless row

      begin
        password = @encryption.decrypt(row['smtp_pass'])
      rescue StandardError => e
        return json({ success: false, message: "Stored password could not be decrypted: #{e.message}" })
      end

      result = @smtp_test.test(
        smtp_host: row['smtp_host'],
        smtp_port: row['smtp_port'],
        smtp_user: row['smtp_user'],
        smtp_pass: password
      )

      json(result)
    end

    # DELETE /admin/clients/:id
    def delete_client(client_id)
      return error('Client not found', 404) unless load_client(client_id)

      Services::Database.query('DELETE FROM clients WHERE id = ?', [client_id])
      json({ message: 'Client deleted' })
    end

    # ── Mail logs ──────────────────────────────────────────────────────

    # GET /admin/logs[?organization_id=&client_id=&status=&q=&limit=&offset=]
    def logs(request)
      params = request.params
      conditions = []
      values = []

      if present?(params['organization_id'])
        conditions << 'c.organization_id = ?'
        values << params['organization_id'].to_i
      end

      if present?(params['client_id'])
        conditions << 'ml.client_id = ?'
        values << params['client_id'].to_i
      end

      if %w[sent failed unknown].include?(params['status'])
        conditions << 'ml.status = ?'
        values << params['status']
      end

      if present?(params['q'])
        conditions << '(ml.subject LIKE ? OR ml.to_address LIKE ?)'
        needle = "%#{params['q']}%"
        values << needle << needle
      end

      where  = conditions.empty? ? '' : "WHERE #{conditions.join(' AND ')}"
      limit  = (params['limit'] || DEFAULT_LIMIT).to_i.clamp(1, MAX_LIMIT)
      offset = (params['offset'] || 0).to_i.clamp(0, 1_000_000)

      rows = Services::Database.query(<<~SQL, values)
        SELECT ml.*, c.from_address, c.organization_id, o.name AS organization_name
          FROM mail_logs ml
          JOIN clients c ON c.id = ml.client_id
          JOIN organizations o ON o.id = c.organization_id
          #{where}
         ORDER BY ml.created_at DESC
         LIMIT #{limit} OFFSET #{offset}
      SQL

      total = Services::Database.query(<<~SQL, values).first['c']
        SELECT COUNT(*) AS c
          FROM mail_logs ml
          JOIN clients c ON c.id = ml.client_id
          #{where}
      SQL

      json({ logs: rows.map { |r| serialize_log(r) }, total: total, limit: limit, offset: offset })
    end

    private

    # ── Serializers ────────────────────────────────────────────────────

    def serialize_organization(row)
      {
        id:           row['id'],
        name:         row['name'],
        slug:         row['slug'],
        clientsCount: row['clients_count'],
        logsCount:    row['logs_count'],
        createdAt:    row['created_at']&.to_s
      }
    end

    # NOTE: apiKey is deliberately exposed here. The admin UI needs it to call
    # the client-scoped endpoints (/send, /telegram/*) on the operator's behalf.
    # smtp_pass is never returned.
    def serialize_client(row)
      {
        id:               row['id'],
        organizationId:   row['organization_id'],
        organizationName: row['organization_name'],
        organizationSlug: row['organization_slug'],
        apiKey:           row['api_key'],
        smtpHost:         row['smtp_host'],
        smtpPort:         row['smtp_port'],
        smtpUser:         row['smtp_user'],
        fromAddress:      row['from_address'],
        logsCount:        row['logs_count'],
        botsCount:        row['bots_count'],
        createdAt:        row['created_at']&.to_s
      }
    end

    def serialize_log(row)
      {
        id:               row['id'],
        clientId:         row['client_id'],
        organizationId:   row['organization_id'],
        organizationName: row['organization_name'],
        fromAddress:      row['from_address'],
        toAddress:        parse_json_field(row['to_address']),
        cc:               parse_json_field(row['cc']),
        bcc:              parse_json_field(row['bcc']),
        replyTo:          row['reply_to'],
        priority:         row['priority'],
        subject:          row['subject'],
        status:           row['status'],
        error:            row['error'],
        createdAt:        row['created_at']&.to_s
      }
    end

    # ── Lookups ────────────────────────────────────────────────────────

    def find_organization(org_id)
      Services::Database.query(
        'SELECT o.*,
                (SELECT COUNT(*) FROM clients c WHERE c.organization_id = o.id) AS clients_count,
                (SELECT COUNT(*) FROM mail_logs ml
                   JOIN clients c2 ON c2.id = ml.client_id
                  WHERE c2.organization_id = o.id) AS logs_count
           FROM organizations o WHERE o.id = ?', [org_id]
      ).first
    end

    def load_client(client_id)
      Services::Database.query(
        'SELECT c.*, o.name AS organization_name, o.slug AS organization_slug,
                (SELECT COUNT(*) FROM mail_logs ml WHERE ml.client_id = c.id) AS logs_count,
                (SELECT COUNT(*) FROM client_telegram_bots b WHERE b.client_id = c.id) AS bots_count
           FROM clients c
           JOIN organizations o ON o.id = c.organization_id
          WHERE c.id = ?', [client_id]
      ).first
    end

    def scalar(sql)
      Services::Database.query(sql).first['c']
    end

    # ── Helpers (mirrors the other handlers) ───────────────────────────

    def parse_json(request)
      body = request.body.read
      request.body.rewind
      parsed = JSON.parse(body)
      parsed.is_a?(Hash) ? parsed : {}
    rescue JSON::ParserError
      {}
    end

    def parse_json_field(value)
      return value unless value.is_a?(String)

      JSON.parse(value)
    rescue JSON::ParserError
      value
    end

    def blank?(value)
      value.nil? || value.to_s.strip.empty?
    end

    def present?(value)
      !blank?(value)
    end

    def json(payload, status = 200)
      [status, { 'Content-Type' => 'application/json' }, [JSON.generate(payload)]]
    end

    def error(message, status, details: nil)
      payload = { error: message }
      payload[:details] = details if details
      json(payload, status)
    end
  end
end
