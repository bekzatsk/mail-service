# frozen_string_literal: true

require 'dotenv'
Dotenv.load(File.join(__dir__, '.env'))

# Refuse to boot on a key that cannot protect anything. The example file ships
# a placeholder, and a service that starts with it encrypts every stored
# password under a value that is public.
require_relative 'app/services/boot_check'
Services::BootCheck.run!

# Run database migrations on startup
require_relative 'app/services/migrator'
Services::Migrator.new.run!

# Boot Telegram bot listeners (one thread per enabled bot)
require_relative 'app/services/telegram_bot_supervisor'
Services::TelegramBotSupervisor.instance.boot!

require_relative 'app'
require_relative 'app/middleware/security_headers'
require_relative 'app/middleware/body_limit'
require_relative 'app/middleware/api_key_middleware'

# Rack middleware stack, outermost first
use Middleware::SecurityHeaders
use Middleware::BodyLimit
use Middleware::ApiKeyMiddleware

run App
