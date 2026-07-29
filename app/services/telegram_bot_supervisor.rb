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

      rows = Database.query('SELECT id FROM client_telegram_bots WHERE is_enabled = TRUE')
      rows.each { |row| start(row['id']) }

      puts "[telegram-supervisor] booted with #{@listeners.size} listener(s)"
    rescue StandardError => e
      warn "[telegram-supervisor] boot failed: #{e.class}: #{e.message}"
    end

    def start(bot_id)
      bot_id = bot_id.to_i
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
