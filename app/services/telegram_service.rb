# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'

module Services
  class TelegramService
    API_BASE = 'https://api.telegram.org'

    class ApiError < StandardError
      attr_reader :code
      def initialize(message, code: nil)
        super(message)
        @code = code
      end
    end

    class ConflictError < ApiError; end

    def get_me(token)
      call(token, 'getMe', {})
    end

    def send_message(token, chat_id:, text:, parse_mode: nil, reply_to_message_id: nil, disable_notification: false)
      payload = { chat_id: chat_id, text: text, disable_notification: disable_notification }
      payload[:parse_mode] = parse_mode if parse_mode && !parse_mode.to_s.empty?
      payload[:reply_to_message_id] = reply_to_message_id if reply_to_message_id
      call(token, 'sendMessage', payload)
    end

    def get_updates(token, offset:, timeout: 30)
      call(token, 'getUpdates', { offset: offset, timeout: timeout }, read_timeout: timeout + 10)
    end

    def set_my_commands(token, commands)
      call(token, 'setMyCommands', { commands: commands })
    end

    def delete_my_commands(token)
      call(token, 'deleteMyCommands', {})
    end

    private

    def call(token, method, payload, read_timeout: 30)
      uri = URI("#{API_BASE}/bot#{token}/#{method}")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 10
      http.read_timeout = read_timeout

      req = Net::HTTP::Post.new(uri.request_uri)
      req['Content-Type'] = 'application/json'
      req['User-Agent'] = ENV.fetch('TELEGRAM_HTTP_USER_AGENT', 'mail-service/telegram-gateway')
      req.body = JSON.generate(payload)

      response = http.request(req)
      body = parse_body(response.body)

      if response.code.to_i == 409
        raise ConflictError.new(body['description'] || 'Conflict', code: 409)
      end

      unless body.is_a?(Hash) && body['ok']
        description = body.is_a?(Hash) ? (body['description'] || "HTTP #{response.code}") : "HTTP #{response.code}"
        code = body.is_a?(Hash) ? (body['error_code'] || response.code.to_i) : response.code.to_i
        raise ApiError.new(description, code: code)
      end

      body['result']
    end

    def parse_body(raw)
      JSON.parse(raw.to_s)
    rescue JSON::ParserError
      {}
    end
  end
end
