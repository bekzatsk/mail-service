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

      # Validate: to is required (string or array)
      to = data['to']
      if to.nil? || (to.is_a?(String) && to.empty?) || (to.is_a?(Array) && to.compact.reject(&:empty?).empty?)
        return json_response({ error: 'Missing required field: to' }, 400)
      end

      params = {
        to:       Array(to).compact.reject(&:empty?),
        cc:       data['cc'],
        bcc:      data['bcc'],
        reply_to: data['replyTo'],
        from:     data['from'],
        subject:  data['subject'] || '(no subject)',
        body:     data['body'] || '',
        is_html:  data['isHtml'],
        priority: data['priority'],
        headers:  data['headers']
      }

      result = @mail_service.send(client, params)

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
        'SELECT ml.id, ml.to_address, ml.cc, ml.bcc, ml.reply_to, ml.priority, ml.subject, ml.status, ml.error, ml.created_at
         FROM mail_logs ml
         JOIN clients c ON c.id = ml.client_id
         WHERE c.organization_id = ?
         ORDER BY ml.created_at DESC LIMIT 100',
        [client['organization_id']]
      )

      logs = results.map do |row|
        entry = {
          id:         row['id'],
          to_address: parse_json_field(row['to_address']),
          subject:    row['subject'],
          status:     row['status'],
          error:      row['error'],
          created_at: row['created_at']&.to_s
        }
        entry[:cc]       = parse_json_field(row['cc']) if row['cc']
        entry[:bcc]      = parse_json_field(row['bcc']) if row['bcc']
        entry[:reply_to] = row['reply_to'] if row['reply_to']
        entry[:priority] = row['priority'] if row['priority']
        entry
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

    def parse_json_field(value)
      return value unless value.is_a?(String)

      JSON.parse(value)
    rescue JSON::ParserError
      value
    end

    def json_response(payload, status = 200)
      [status, { 'Content-Type' => 'application/json' }, [JSON.generate(payload)]]
    end
  end
end
