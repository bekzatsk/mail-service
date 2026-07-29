# frozen_string_literal: true

require 'json'
require_relative '../services/database'
require_relative '../services/encryption_service'
require_relative '../services/telegram_service'
require_relative '../services/telegram_bot_supervisor'
require_relative '../services/telegram_command_sync'

module Handlers
  class TelegramHandler
    def initialize
      @encryption   = Services::EncryptionService.new
      @telegram     = Services::TelegramService.new
      @command_sync = Services::TelegramCommandSync.new
    end

    # ── Bots ───────────────────────────────────────────────────────────

    # POST /telegram/bots/test
    def test_bot(request, _client)
      data = parse_json(request)
      token = data['botToken']
      return error('Missing required field: botToken', 400) if blank?(token)

      begin
        result = @telegram.get_me(token)
        json({ success: true, username: result['username'], botId: result['id'] })
      rescue Services::TelegramService::ApiError => e
        json({ success: false, message: e.message })
      rescue StandardError => e
        json({ success: false, message: "#{e.class}: #{e.message}" })
      end
    end

    # POST /telegram/bots
    def create_bot(request, client)
      data = parse_json(request)
      name = data['name'].to_s.strip
      token = data['botToken']
      is_default_req = data['isDefault'] == true

      return error('Missing required field: name', 400) if name.empty?
      return error('Missing required field: botToken', 400) if blank?(token)

      begin
        me = @telegram.get_me(token)
      rescue StandardError => e
        return error('Bot token validation failed', 400, details: e.message)
      end

      existing = Services::Database.query(
        'SELECT id FROM client_telegram_bots WHERE client_id = ? AND name = ?',
        [client['id'], name]
      ).first
      return error("Bot with name '#{name}' already exists", 409) if existing

      encrypted_token = @encryption.encrypt(token)

      Services::Database.query(
        'INSERT INTO client_telegram_bots (client_id, name, bot_token, bot_username, bot_id, is_default) VALUES (?, ?, ?, ?, ?, ?)',
        [client['id'], name, encrypted_token, me['username'], me['id'], is_default_req ? 1 : 0]
      )
      bot_id = Services::Database.connection.last_id

      if is_default_req
        Services::Database.query(
          'UPDATE client_telegram_bots SET is_default = FALSE WHERE client_id = ? AND id != ?',
          [client['id'], bot_id]
        )
      else
        any_default = Services::Database.query(
          'SELECT id FROM client_telegram_bots WHERE client_id = ? AND is_default = TRUE',
          [client['id']]
        ).first
        unless any_default
          Services::Database.query(
            'UPDATE client_telegram_bots SET is_default = TRUE WHERE id = ?',
            [bot_id]
          )
        end
      end

      Services::TelegramBotSupervisor.instance.start(bot_id)

      json({ bot: serialize_bot(load_bot(bot_id)) }, 201)
    end

    # GET /telegram/bots
    def list_bots(client)
      rows = Services::Database.query(
        'SELECT * FROM client_telegram_bots WHERE client_id = ? ORDER BY created_at ASC',
        [client['id']]
      )
      json({ bots: rows.map { |r| serialize_bot(r) } })
    end

    # GET /telegram/bots/:id
    def show_bot(client, bot_id)
      bot = find_client_bot(client, bot_id)
      return error('Bot not found', 404) unless bot
      json({ bot: serialize_bot(bot) })
    end

    # PATCH /telegram/bots/:id
    def update_bot(request, client, bot_id)
      bot = find_client_bot(client, bot_id)
      return error('Bot not found', 404) unless bot

      data = parse_json(request)
      sets = []
      params = []
      restart_listener = false

      if data.key?('name')
        return error('name cannot be empty', 400) if blank?(data['name'])
        sets << 'name = ?'; params << data['name'].to_s.strip
      end

      if data.key?('isEnabled')
        sets << 'is_enabled = ?'; params << (data['isEnabled'] ? 1 : 0)
        restart_listener = true
      end

      if data.key?('botToken') && !blank?(data['botToken'])
        begin
          me = @telegram.get_me(data['botToken'])
        rescue StandardError => e
          return error('Bot token validation failed', 400, details: e.message)
        end
        sets << 'bot_token = ?';    params << @encryption.encrypt(data['botToken'])
        sets << 'bot_username = ?'; params << me['username']
        sets << 'bot_id = ?';       params << me['id']
        restart_listener = true
      end

      if data.key?('isDefault')
        sets << 'is_default = ?'; params << (data['isDefault'] ? 1 : 0)
      end

      return error('No fields to update', 400) if sets.empty?

      params << bot_id
      Services::Database.query(
        "UPDATE client_telegram_bots SET #{sets.join(', ')} WHERE id = ?",
        params
      )

      if data['isDefault'] == true
        Services::Database.query(
          'UPDATE client_telegram_bots SET is_default = FALSE WHERE client_id = ? AND id != ?',
          [client['id'], bot_id]
        )
      end

      updated = load_bot(bot_id)

      if restart_listener
        sup = Services::TelegramBotSupervisor.instance
        if updated['is_enabled'] == 1 || updated['is_enabled'] == true
          sup.restart(bot_id)
        else
          sup.stop(bot_id)
        end
      end

      json({ bot: serialize_bot(updated) })
    end

    # DELETE /telegram/bots/:id
    def delete_bot(client, bot_id)
      bot = find_client_bot(client, bot_id)
      return error('Bot not found', 404) unless bot

      Services::TelegramBotSupervisor.instance.stop(bot_id)
      Services::Database.query('DELETE FROM client_telegram_bots WHERE id = ?', [bot_id])
      json({ message: 'Bot deleted' })
    end

    # POST /telegram/bots/:id/sync-commands
    def sync_commands(client, bot_id)
      bot = find_client_bot(client, bot_id)
      return error('Bot not found', 404) unless bot

      ok = @command_sync.sync!(bot['id'])
      json({ success: ok })
    end

    # ── Messages ───────────────────────────────────────────────────────

    # POST /telegram/messages
    def send_message(request, client)
      data = parse_json(request)
      chat_id = data['chatId']
      text    = data['text']

      return error('Missing required field: chatId', 400) if chat_id.nil?
      return error('Missing required field: text', 400) if blank?(text)

      bot = resolve_bot(client, data)
      return error('Bot not found', 404) unless bot
      return error('Bot is disabled', 400) unless bot['is_enabled'] == 1 || bot['is_enabled'] == true

      token       = @encryption.decrypt(bot['bot_token'])
      parse_mode  = data['parseMode']
      reply_to    = data['replyToMessageId']
      disable_notif = data['disableNotification'] == true

      begin
        result = @telegram.send_message(
          token,
          chat_id: chat_id,
          text: text,
          parse_mode: parse_mode,
          reply_to_message_id: reply_to,
          disable_notification: disable_notif
        )
        Services::Database.query(
          'INSERT INTO telegram_messages (bot_id, client_id, direction, chat_id, telegram_message_id, text, parse_mode, status) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
          [bot['id'], client['id'], 'outbound', chat_id, result['message_id'], text, parse_mode, 'sent']
        )
        msg_id = Services::Database.connection.last_id
        json({ id: msg_id, telegramMessageId: result['message_id'], status: 'sent' })
      rescue StandardError => e
        Services::Database.query(
          'INSERT INTO telegram_messages (bot_id, client_id, direction, chat_id, text, parse_mode, status, error_message) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
          [bot['id'], client['id'], 'outbound', chat_id, text, parse_mode, 'failed', e.message]
        )
        error('Failed to send message', 500, details: e.message)
      end
    end

    # GET /telegram/messages
    def list_messages(request, client)
      params = request.params
      conditions = ['client_id = ?']
      values = [client['id']]

      if params['botId']
        conditions << 'bot_id = ?'
        values << params['botId'].to_i
      end
      if params['chatId']
        conditions << 'chat_id = ?'
        values << params['chatId'].to_i
      end
      if params['direction']
        conditions << 'direction = ?'
        values << params['direction']
      end

      limit  = (params['limit']  || 100).to_i.clamp(1, 500)
      offset = (params['offset'] || 0).to_i.clamp(0, 1_000_000)

      sql = "SELECT * FROM telegram_messages WHERE #{conditions.join(' AND ')} ORDER BY created_at DESC LIMIT #{limit} OFFSET #{offset}"
      rows = Services::Database.query(sql, values)
      json({ messages: rows.map { |r| serialize_message(r) } })
    end

    # GET /telegram/messages/:id
    def show_message(client, msg_id)
      row = Services::Database.query(
        'SELECT * FROM telegram_messages WHERE id = ? AND client_id = ?',
        [msg_id, client['id']]
      ).first
      return error('Message not found', 404) unless row
      json({ message: serialize_message(row) })
    end

    # ── Chats ──────────────────────────────────────────────────────────

    # POST /telegram/chats
    def create_chat(request, client)
      data = parse_json(request)
      chat_id = data['chatId']
      return error('Missing required field: chatId', 400) if chat_id.nil?

      bot = resolve_bot(client, data)
      return error('Bot not found', 404) unless bot

      chat_type = data['chatType'] || 'private'
      unless %w[private group supergroup channel].include?(chat_type)
        return error('Invalid chatType (private|group|supergroup|channel)', 400)
      end
      title = data['title']

      existing = Services::Database.query(
        'SELECT * FROM telegram_chats WHERE bot_id = ? AND chat_id = ?',
        [bot['id'], chat_id]
      ).first
      return json({ chat: serialize_chat(existing) }) if existing

      Services::Database.query(
        'INSERT INTO telegram_chats (bot_id, chat_id, title, chat_type) VALUES (?, ?, ?, ?)',
        [bot['id'], chat_id, title, chat_type]
      )
      new_id = Services::Database.connection.last_id
      row = Services::Database.query('SELECT * FROM telegram_chats WHERE id = ?', [new_id]).first
      json({ chat: serialize_chat(row) }, 201)
    end

    # GET /telegram/chats
    def list_chats(request, client)
      params = request.params
      rows = if params['botId']
               bot = find_client_bot(client, params['botId'].to_i)
               return error('Bot not found', 404) unless bot
               Services::Database.query(
                 'SELECT * FROM telegram_chats WHERE bot_id = ? ORDER BY created_at DESC',
                 [bot['id']]
               )
             else
               Services::Database.query(
                 'SELECT c.* FROM telegram_chats c JOIN client_telegram_bots b ON b.id = c.bot_id WHERE b.client_id = ? ORDER BY c.created_at DESC',
                 [client['id']]
               )
             end
      json({ chats: rows.map { |r| serialize_chat(r) } })
    end

    # DELETE /telegram/chats/:id
    def delete_chat(client, chat_pk)
      row = Services::Database.query(
        'SELECT c.* FROM telegram_chats c JOIN client_telegram_bots b ON b.id = c.bot_id WHERE c.id = ? AND b.client_id = ?',
        [chat_pk, client['id']]
      ).first
      return error('Chat not found', 404) unless row

      Services::Database.query('DELETE FROM telegram_chats WHERE id = ?', [chat_pk])
      json({ message: 'Chat deleted' })
    end

    # ── Commands ───────────────────────────────────────────────────────

    # POST /telegram/commands
    def create_command(request, client)
      data = parse_json(request)
      command     = data['command']
      description = data['description']
      handler_url = data['handlerUrl']

      return error('Missing required field: command', 400) if blank?(command)
      return error('Missing required field: description', 400) if blank?(description)
      return error('Invalid command (1-32 chars, [a-z0-9_], no slash)', 400) unless command.to_s =~ /\A[a-z0-9_]{1,32}\z/i

      bot = resolve_bot(client, data)
      return error('Bot not found', 404) unless bot

      command = command.to_s.downcase
      existing = Services::Database.query(
        'SELECT id FROM telegram_commands WHERE bot_id = ? AND command = ?',
        [bot['id'], command]
      ).first
      return error("Command '#{command}' already exists for bot", 409) if existing

      Services::Database.query(
        'INSERT INTO telegram_commands (bot_id, command, description, handler_url, handler_secret) VALUES (?, ?, ?, ?, ?)',
        [bot['id'], command, description, handler_url, data['handlerSecret']]
      )
      new_id = Services::Database.connection.last_id

      @command_sync.sync!(bot['id'])

      row = Services::Database.query('SELECT * FROM telegram_commands WHERE id = ?', [new_id]).first
      json({ command: serialize_command(row) }, 201)
    end

    # GET /telegram/commands
    def list_commands(request, client)
      params = request.params
      rows = if params['botId']
               bot = find_client_bot(client, params['botId'].to_i)
               return error('Bot not found', 404) unless bot
               Services::Database.query(
                 'SELECT * FROM telegram_commands WHERE bot_id = ? ORDER BY command ASC',
                 [bot['id']]
               )
             else
               Services::Database.query(
                 'SELECT c.* FROM telegram_commands c JOIN client_telegram_bots b ON b.id = c.bot_id WHERE b.client_id = ? ORDER BY c.command ASC',
                 [client['id']]
               )
             end
      json({ commands: rows.map { |r| serialize_command(r) } })
    end

    # PATCH /telegram/commands/:id
    def update_command(request, client, cmd_id)
      row = find_client_command(client, cmd_id)
      return error('Command not found', 404) unless row

      data = parse_json(request)
      sets = []
      params = []

      if data.key?('description')
        return error('description cannot be empty', 400) if blank?(data['description'])
        sets << 'description = ?'; params << data['description']
      end
      if data.key?('handlerUrl')
        sets << 'handler_url = ?'; params << data['handlerUrl']
      end
      if data.key?('handlerSecret')
        sets << 'handler_secret = ?'; params << data['handlerSecret']
      end
      if data.key?('isEnabled')
        sets << 'is_enabled = ?'; params << (data['isEnabled'] ? 1 : 0)
      end

      return error('No fields to update', 400) if sets.empty?

      params << cmd_id
      Services::Database.query(
        "UPDATE telegram_commands SET #{sets.join(', ')} WHERE id = ?",
        params
      )

      @command_sync.sync!(row['bot_id'])

      updated = Services::Database.query('SELECT * FROM telegram_commands WHERE id = ?', [cmd_id]).first
      json({ command: serialize_command(updated) })
    end

    # DELETE /telegram/commands/:id
    def delete_command(client, cmd_id)
      row = find_client_command(client, cmd_id)
      return error('Command not found', 404) unless row

      Services::Database.query('DELETE FROM telegram_commands WHERE id = ?', [cmd_id])
      @command_sync.sync!(row['bot_id'])
      json({ message: 'Command deleted' })
    end

    private

    def find_client_bot(client, bot_id)
      Services::Database.query(
        'SELECT * FROM client_telegram_bots WHERE id = ? AND client_id = ?',
        [bot_id, client['id']]
      ).first
    end

    def find_client_command(client, cmd_id)
      Services::Database.query(
        'SELECT c.* FROM telegram_commands c JOIN client_telegram_bots b ON b.id = c.bot_id WHERE c.id = ? AND b.client_id = ?',
        [cmd_id, client['id']]
      ).first
    end

    def load_bot(bot_id)
      Services::Database.query(
        'SELECT * FROM client_telegram_bots WHERE id = ?', [bot_id]
      ).first
    end

    # Resolves a bot from {botId} → {botName} → default. Always scoped to client.
    def resolve_bot(client, data)
      if data['botId']
        find_client_bot(client, data['botId'].to_i)
      elsif data['botName'] && !data['botName'].to_s.empty?
        Services::Database.query(
          'SELECT * FROM client_telegram_bots WHERE client_id = ? AND name = ?',
          [client['id'], data['botName'].to_s]
        ).first
      else
        Services::Database.query(
          'SELECT * FROM client_telegram_bots WHERE client_id = ? AND is_default = TRUE',
          [client['id']]
        ).first
      end
    end

    def serialize_bot(row)
      {
        id:           row['id'],
        name:         row['name'],
        botUsername:  row['bot_username'],
        botId:        row['bot_id'],
        isEnabled:    row['is_enabled'] == 1 || row['is_enabled'] == true,
        isDefault:    row['is_default'] == 1 || row['is_default'] == true,
        lastError:    row['last_error'],
        lastSeen:     row['last_seen']&.to_s,
        createdAt:    row['created_at']&.to_s,
        updatedAt:    row['updated_at']&.to_s
      }
    end

    def serialize_chat(row)
      {
        id:        row['id'],
        botId:     row['bot_id'],
        chatId:    row['chat_id'],
        title:     row['title'],
        chatType:  row['chat_type'],
        createdAt: row['created_at']&.to_s
      }
    end

    def serialize_command(row)
      {
        id:               row['id'],
        botId:            row['bot_id'],
        command:          row['command'],
        description:      row['description'],
        handlerUrl:       row['handler_url'],
        hasHandlerSecret: !(row['handler_secret'].nil? || row['handler_secret'].to_s.empty?),
        isEnabled:        row['is_enabled'] == 1 || row['is_enabled'] == true,
        createdAt:        row['created_at']&.to_s,
        updatedAt:        row['updated_at']&.to_s
      }
    end

    def serialize_message(row)
      {
        id:                row['id'],
        botId:             row['bot_id'],
        direction:         row['direction'],
        chatId:            row['chat_id'],
        telegramMessageId: row['telegram_message_id'],
        userId:            row['user_id'],
        username:          row['username'],
        text:              row['text'],
        parseMode:         row['parse_mode'],
        status:            row['status'],
        errorMessage:      row['error_message'],
        createdAt:         row['created_at']&.to_s
      }
    end

    def parse_json(request)
      body = request.body.read
      request.body.rewind
      JSON.parse(body)
    rescue JSON::ParserError
      {}
    end

    def blank?(value)
      value.nil? || value.to_s.empty?
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
