# frozen_string_literal: true

require_relative 'database'
require_relative 'encryption_service'
require_relative 'telegram_service'

module Services
  class TelegramCommandSync
    def initialize
      @telegram   = TelegramService.new
      @encryption = EncryptionService.new
    end

    # Push current telegram_commands rows for a bot to Telegram via setMyCommands.
    # Empty list → deleteMyCommands. Swallows failures (logs warn) so callers don't break.
    def sync!(bot_id)
      bot = Database.query(
        'SELECT bot_token FROM client_telegram_bots WHERE id = ?', [bot_id]
      ).first
      return false unless bot

      token = @encryption.decrypt(bot['bot_token'])

      commands = Database.query(
        'SELECT command, description FROM telegram_commands WHERE bot_id = ? AND is_enabled = TRUE ORDER BY command',
        [bot_id]
      ).map { |r| { command: r['command'], description: r['description'] } }

      if commands.empty?
        @telegram.delete_my_commands(token)
      else
        @telegram.set_my_commands(token, commands)
      end
      true
    rescue StandardError => e
      warn "[telegram-command-sync:#{bot_id}] #{e.class}: #{e.message}"
      false
    end
  end
end
