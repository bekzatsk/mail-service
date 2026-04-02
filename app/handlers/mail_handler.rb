# frozen_string_literal: true

require_relative '../services/database'
require_relative '../services/mail_service'

module Handlers
  class MailHandler
    def initialize
      @mail_service = Services::MailService.new
    end

    # POST /send
    # Send an email using the authenticated client's SMTP config.
    def send_mail(request, client)
      data = parse_json(request)

      if data['to'].nil? || data['to'].to_s.empty?
        return json_response({ error: 'Missing required field: to' }, 400)
      end

      to      = data['to']
      subject = data['subject'] || '(no subject)'
      body    = data['body'] || ''

      result = @mail_service.send(client, to, subject, body)

      if result[:success]
        json_response({ message: 'Email sent successfully' })
      else
        json_response({ error: 'Failed to send email', details: result[:error] }, 500)
      end
    end

    # GET /logs
    # Retrieve mail send history for the authenticated client.
    def logs(client)
      results = Services::Database.query(
        'SELECT ml.id, ml.to_address, ml.subject, ml.status, ml.error, ml.created_at
         FROM mail_logs ml
         JOIN clients c ON c.id = ml.client_id
         WHERE c.organization_id = ?
         ORDER BY ml.created_at DESC LIMIT 100',
        [client['organization_id']]
      )

      logs = results.map do |row|
        {
          id:         row['id'],
          to_address: row['to_address'],
          subject:    row['subject'],
          status:     row['status'],
          error:      row['error'],
          created_at: row['created_at']&.to_s
        }
      end

      json_response({
        organization: {
          id:   client['organization_id'],
          name: client['organization_name']
        },
        logs: logs
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
