# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'
require_relative 'database'
require_relative 'encryption_service'
require_relative 'telegram_service'

module Services
  # Turns one Telegram update into its side effects: log it, match a slash
  # command, POST it to the command's handler, send the reply back.
  #
  # This used to live inside TelegramBotListener. It was lifted out when the
  # webhook transport arrived, so polling and webhooks run identical logic
  # rather than drifting apart — the transport decides how an update arrives,
  # never what happens to it.
  class TelegramUpdateProcessor
    def initialize
      @telegram   = TelegramService.new
      @encryption = EncryptionService.new
    end

    # @param bot [Hash] row from client_telegram_bots
    # @param update [Hash] raw Telegram update
    def process(bot, update)
      msg = update['message'] || update['edited_message']
      return unless msg

      chat = msg['chat'] || {}
      from = msg['from'] || {}
      text = msg['text'].to_s

      log_inbound(bot, msg, chat, from, text)

      return unless text.start_with?('/')

      match = text.match(%r{\A/([A-Za-z0-9_]{1,32})(?:@\S+)?\s*(.*)\z}m)
      return unless match

      command = match[1].downcase
      args    = match[2].to_s

      cmd_row = Database.query(
        'SELECT * FROM telegram_commands WHERE bot_id = ? AND command = ? AND is_enabled = TRUE',
        [bot['id'], command]
      ).first

      if cmd_row
        dispatch_command(bot, msg, cmd_row, command, args)
      elsif ENV.fetch('TELEGRAM_UNKNOWN_COMMAND_REPLY', 'false') == 'true'
        send_text(bot, chat['id'], 'Unknown command', reply_to: msg['message_id'])
      end
    end

    private

    def log_inbound(bot, msg, chat, from, text)
      Database.query(
        'INSERT INTO telegram_messages (bot_id, client_id, direction, chat_id, telegram_message_id, user_id, username, text, status) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [bot['id'], bot['client_id'], 'inbound', chat['id'], msg['message_id'], from['id'], from['username'], text, 'received']
      )
    rescue StandardError => e
      warn "[telegram-processor:#{bot['id']}] log_inbound failed: #{e.message}"
    end

    def dispatch_command(bot, msg, cmd_row, command, args)
      return if cmd_row['handler_url'].to_s.empty?

      payload = {
        chatId:    msg.dig('chat', 'id'),
        userId:    msg.dig('from', 'id'),
        username:  msg.dig('from', 'username'),
        command:   command,
        args:      args,
        messageId: msg['message_id'],
        botId:     bot['id'],
        botName:   bot['name']
      }

      uri = URI.parse(cmd_row['handler_url'])
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'
      http.open_timeout = 5
      http.read_timeout = ENV.fetch('TELEGRAM_HANDLER_TIMEOUT_SECONDS', '10').to_i

      req = Net::HTTP::Post.new(uri.request_uri)
      req['Content-Type'] = 'application/json'
      req['User-Agent']   = ENV.fetch('TELEGRAM_HTTP_USER_AGENT', 'mail-service/telegram-gateway')
      req['X-Handler-Secret'] = cmd_row['handler_secret'] if cmd_row['handler_secret'] && !cmd_row['handler_secret'].empty?
      req.body = JSON.generate(payload)

      response = http.request(req)
      body = begin
        JSON.parse(response.body)
      rescue StandardError
        {}
      end
      reply_text = body['text']
      return unless reply_text && !reply_text.to_s.empty?

      send_text(
        bot,
        msg.dig('chat', 'id'),
        reply_text,
        parse_mode: body['parseMode'],
        reply_to: msg['message_id']
      )
    rescue StandardError => e
      warn "[telegram-handler:#{bot['id']}/#{command}] #{e.class}: #{e.message}"
    end

    def send_text(bot, chat_id, text, parse_mode: nil, reply_to: nil)
      token = @encryption.decrypt(bot['bot_token'])
      result = @telegram.send_message(
        token,
        chat_id: chat_id,
        text: text,
        parse_mode: parse_mode,
        reply_to_message_id: reply_to
      )
      Database.query(
        'INSERT INTO telegram_messages (bot_id, client_id, direction, chat_id, telegram_message_id, text, parse_mode, status) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
        [bot['id'], bot['client_id'], 'outbound', chat_id, result['message_id'], text, parse_mode, 'sent']
      )
    rescue StandardError => e
      Database.query(
        'INSERT INTO telegram_messages (bot_id, client_id, direction, chat_id, text, parse_mode, status, error_message) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
        [bot['id'], bot['client_id'], 'outbound', chat_id, text, parse_mode, 'failed', e.message]
      )
      warn "[telegram-processor:#{bot['id']}] send_text failed: #{e.message}"
    end
  end
end
