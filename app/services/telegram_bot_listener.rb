# frozen_string_literal: true

require_relative 'database'
require_relative 'encryption_service'
require_relative 'telegram_service'
require_relative 'telegram_update_processor'

module Services
  # Long-poll transport: one instance per bot, running getUpdates in its own
  # thread. What to do with an update lives in TelegramUpdateProcessor, shared
  # with the webhook transport.
  #
  # Only bots with delivery_mode = 'polling' get a listener; see
  # TelegramBotSupervisor.
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
      @processor  = TelegramUpdateProcessor.new
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
        unless bot && truthy?(bot['is_enabled']) && bot['delivery_mode'].to_s != 'webhook'
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
            @processor.process(bot, update)
            update_offset(update['update_id'])
          end
        rescue TelegramService::ConflictError => e
          # Another getUpdates consumer holds this bot: a second app process, or
          # a webhook still registered. Backing off is the only safe response.
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

    def truthy?(value)
      value == 1 || value == true
    end

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
  end
end
