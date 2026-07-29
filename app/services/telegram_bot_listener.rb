# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'
require_relative 'database'
require_relative 'encryption_service'
require_relative 'telegram_service'

module Services
  class TelegramBotListener
    BACKOFF_SCHEDULE = [1, 2, 5, 10, 30].freeze
    CONFLICT_SLEEP   = 60
    BOT_RELOAD_SLEEP = 5

    def initialize(bot_id:)
      @bot_id     = bot_id
      @stop       = false
      @mutex      = Mutex.new
      @telegram   = TelegramService.new
      @encryption = EncryptionService.new
    end

    def stop!
      @mutex.synchronize { @stop = true }
    end

    def stopped?
      @mutex.synchronize { @stop }
    end

    def run
      backoff_idx = 0

      until stopped?
        bot = load_bot
        unless bot && (bot['is_enabled'] == 1 || bot['is_enabled'] == true)
          interruptible_sleep(BOT_RELOAD_SLEEP)
          next
        end

        token   = @encryption.decrypt(bot['bot_token'])
        offset  = bot['last_update_id'].to_i + 1
        timeout = ENV.fetch('TELEGRAM_POLL_TIMEOUT_SECONDS', '30').to_i

        begin
          updates = @telegram.get_updates(token, offset: offset, timeout: timeout)
          mark_seen(nil)
          backoff_idx = 0

          updates.each do |update|
            handle_update(bot, update)
            update_offset(update['update_id'])
          end
        rescue TelegramService::ConflictError => e
          mark_seen("409 Conflict: #{e.message}")
          interruptible_sleep(CONFLICT_SLEEP)
        rescue StandardError => e
          mark_seen("#{e.class}: #{e.message}")
          delay = BACKOFF_SCHEDULE[backoff_idx] || BACKOFF_SCHEDULE.last
          backoff_idx = [backoff_idx + 1, BACKOFF_SCHEDULE.length - 1].min
          interruptible_sleep(delay)
        end
      end
    rescue StandardError => e
      warn "[telegram-listener:#{@bot_id}] crashed: #{e.class}: #{e.message}"
    end

    private

    def interruptible_sleep(seconds)
      seconds.times do
        return if stopped?
        sleep 1
      end
    end

    def load_bot
      Database.query(
        'SELECT b.*, COALESCE(s.last_update_id, 0) AS last_update_id
         FROM client_telegram_bots b
         LEFT JOIN telegram_bot_state s ON s.bot_id = b.id
         WHERE b.id = ?', [@bot_id]
      ).first
    end

    def update_offset(update_id)
      Database.query(
        'INSERT INTO telegram_bot_state (bot_id, last_update_id) VALUES (?, ?)
         ON DUPLICATE KEY UPDATE last_update_id = VALUES(last_update_id)',
        [@bot_id, update_id]
      )
    end

    def mark_seen(error)
      Database.query(
        'UPDATE client_telegram_bots SET last_seen = NOW(), last_error = ? WHERE id = ?',
        [error, @bot_id]
      )
    rescue StandardError => e
      warn "[telegram-listener:#{@bot_id}] mark_seen failed: #{e.message}"
    end

    def handle_update(bot, update)
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

    def log_inbound(bot, msg, chat, from, text)
      Database.query(
        'INSERT INTO telegram_messages (bot_id, client_id, direction, chat_id, telegram_message_id, user_id, username, text, status) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [bot['id'], bot['client_id'], 'inbound', chat['id'], msg['message_id'], from['id'], from['username'], text, 'received']
      )
    rescue StandardError => e
      warn "[telegram-listener:#{@bot_id}] log_inbound failed: #{e.message}"
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
      body = JSON.parse(response.body) rescue {}
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
      warn "[telegram-listener:#{@bot_id}] send_text failed: #{e.message}"
    end
  end
end
