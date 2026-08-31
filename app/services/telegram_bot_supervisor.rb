# frozen_string_literal: true

require_relative 'database'
require_relative 'telegram_bot_listener'

module Services
  class TelegramBotSupervisor
    def self.instance
      @instance ||= new
    end

    def initialize
      @mutex     = Mutex.new
      @listeners = {}
      @hook_installed = false
    end

    def boot!
      return unless ENV.fetch('TELEGRAM_ENABLED', 'true') == 'true'

      install_shutdown_hook

      # Webhook bots are driven by inbound requests; giving them a listener too
      # would make both consumers race for getUpdates and earn a 409 from
      # Telegram.
      rows = Database.query(
        "SELECT id FROM client_telegram_bots WHERE is_enabled = TRUE AND delivery_mode = 'polling'"
      )
      rows.each { |row| start(row['id']) }

      puts "[telegram-supervisor] booted with #{@listeners.size} listener(s)"
    rescue StandardError => e
      warn "[telegram-supervisor] boot failed: #{e.class}: #{e.message}"
    end

    # No-op for a bot that is disabled or delivered by webhook, so handlers can
    # call start/restart unconditionally after a write.
    def start(bot_id)
      bot_id = bot_id.to_i
      return unless pollable?(bot_id)

      @mutex.synchronize do
        return if @listeners.key?(bot_id)

        listener = TelegramBotListener.new(bot_id: bot_id)
        thread = Thread.new do
          Thread.current.report_on_exception = false
          listener.run
        end
        thread.name = "tg-bot-#{bot_id}" if thread.respond_to?(:name=)
        @listeners[bot_id] = { thread: thread, listener: listener }
      end
    end

    def stop(bot_id)
      bot_id = bot_id.to_i
      entry = @mutex.synchronize { @listeners.delete(bot_id) }
      return unless entry

      entry[:listener].stop!
      begin
        entry[:thread].kill
      rescue StandardError
        # ignore
      end
    end

    def restart(bot_id)
      stop(bot_id)
      start(bot_id)
    end

    def shutdown!
      ids = @mutex.synchronize { @listeners.keys.dup }
      ids.each { |id| stop(id) }
    end

    private

    def pollable?(bot_id)
      row = Database.query(
        'SELECT is_enabled, delivery_mode FROM client_telegram_bots WHERE id = ?', [bot_id]
      ).first
      return false unless row

      (row['is_enabled'] == 1 || row['is_enabled'] == true) && row['delivery_mode'].to_s != 'webhook'
    rescue StandardError => e
      warn "[telegram-supervisor] pollable? failed for #{bot_id}: #{e.message}"
      false
    end

    def install_shutdown_hook
      return if @hook_installed
      @hook_installed = true

      at_exit { shutdown! }

      %w[TERM INT].each do |sig|
        begin
          Signal.trap(sig) do
            shutdown!
            exit
          end
        rescue ArgumentError
          # Signal not allowed in this environment (e.g. some test runners)
        end
      end
    end
  end
end
