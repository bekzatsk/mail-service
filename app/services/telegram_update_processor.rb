# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'
require_relative 'database'
require_relative 'encryption_service'
require_relative 'telegram_service'
require_relative 'outbound_url_policy'

module Services
  # Turns one Telegram update into its side effects: log it, match a slash
  # command, POST it to the command's handler, send the reply back.
  #
  # This used to live inside TelegramBotListener. It was lifted out when the
  # webhook transport arrived, so polling and webhooks run identical logic
  # rather than drifting apart — the transport decides how an update arrives,
  # never what happens to it.
  class TelegramUpdateProcessor
    # /name, /name@thisbot, optionally followed by arguments.
    #
    # The name must end at whitespace, an @, or the end of the message. Without
    # that anchor, `\s*` let a 34-character token match as a 32-character command
    # plus stray args — Telegram caps a command at 32 and would not treat it as
    # one at all, so ours has to agree or the two disagree about what was sent.
    COMMAND_PATTERN = %r{\A/([A-Za-z0-9_]{1,32})(?:@\S+)?(?:\s+(.*))?\z}m

    # A handler reply is one chat message; anything past this is not parsed.
    MAX_REPLY_BYTES = 64 * 1024

    # Pure: what command, if any, a message text names.
    # Extracted so the dispatch decision can be tested without a database.
    #
    # @return [Array(String, String), nil] [command, args], command downcased
    def self.parse_command(text)
      text = text.to_s
      return nil unless text.start_with?('/')

      match = text.match(COMMAND_PATTERN)
      return nil unless match

      [match[1].downcase, match[2].to_s]
    end

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

      parsed = self.class.parse_command(text)

      if parsed
        cmd_row = Database.query(
          'SELECT * FROM telegram_commands WHERE bot_id = ? AND command = ? AND is_enabled = TRUE',
          [bot['id'], parsed[0]]
        ).first

        if cmd_row
          dispatch_command(bot, msg, cmd_row, parsed[0], parsed[1])
          return
        end
      end

      # Everything a command row did not claim — plain text, and slash commands
      # with no row — goes to the bot's message handler. Without one, a plain
      # message would only ever reach the log, which is the gap this closes.
      unless blank?(bot['message_handler_url'])
        dispatch_message(bot, msg, parsed)
        return
      end

      return unless parsed && ENV.fetch('TELEGRAM_UNKNOWN_COMMAND_REPLY', 'false') == 'true'

      send_text(bot, chat['id'], 'Unknown command', reply_to: msg['message_id'])
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

    def blank?(value)
      value.nil? || value.to_s.strip.empty?
    end

    def base_payload(bot, msg)
      {
        chatId:    msg.dig('chat', 'id'),
        chatType:  msg.dig('chat', 'type'),
        userId:    msg.dig('from', 'id'),
        username:  msg.dig('from', 'username'),
        text:      msg['text'].to_s,
        messageId: msg['message_id'],
        botId:     bot['id'],
        botName:   bot['name']
      }
    end

    def dispatch_command(bot, msg, cmd_row, command, args)
      return if blank?(cmd_row['handler_url'])

      payload = base_payload(bot, msg).merge(command: command, args: args)
      deliver(bot, msg, cmd_row['handler_url'], cmd_row['handler_secret'], payload,
              label: "command:#{command}")
    end

    # Plain messages, and slash commands no row claimed. `parsed` is nil for
    # ordinary text; when it is a command the name and args are passed through
    # so the project can tell the two apart without re-parsing.
    def dispatch_message(bot, msg, parsed)
      payload = base_payload(bot, msg).merge(
        command: parsed&.first,
        args:    parsed ? parsed[1] : nil
      )
      deliver(bot, msg, bot['message_handler_url'], bot['message_handler_secret'], payload,
              label: 'message')
    end

    # POST the payload, and send whatever text comes back into the chat.
    # A handler that answers with no text is choosing silence, which is a normal
    # outcome — most inbound messages do not deserve a reply.
    def deliver(bot, msg, url, secret, payload, label:)
      # The URL passed the policy when it was saved; re-check and resolve now,
      # and connect to the address that passed rather than letting the socket
      # resolve the name a second time. A record that changed since — or that
      # answers differently to our resolver — cannot route this POST inward.
      uri = OutboundUrlPolicy.parse!(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.ipaddr = OutboundUrlPolicy.resolve!(uri.hostname)
      http.use_ssl = uri.scheme == 'https'
      http.open_timeout = 5
      http.read_timeout = ENV.fetch('TELEGRAM_HANDLER_TIMEOUT_SECONDS', '10').to_i

      req = Net::HTTP::Post.new(uri.request_uri)
      req['Content-Type'] = 'application/json'
      req['User-Agent']   = ENV.fetch('TELEGRAM_HTTP_USER_AGENT', 'mail-service/telegram-gateway')
      req['X-Handler-Secret'] = secret unless blank?(secret)
      req.body = JSON.generate(payload)

      response = http.request(req)
      body = begin
        JSON.parse(response.body.to_s[0, MAX_REPLY_BYTES])
      rescue StandardError
        {}
      end
      reply_text = body.is_a?(Hash) ? body['text'] : nil
      return if blank?(reply_text) || !reply_text.is_a?(String)

      send_text(
        bot,
        msg.dig('chat', 'id'),
        reply_text,
        parse_mode: body['parseMode'],
        reply_to: msg['message_id']
      )
    rescue StandardError => e
      warn "[telegram-handler:#{bot['id']}/#{label}] #{e.class}: #{e.message}"
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
