# frozen_string_literal: true

require 'dotenv'
Dotenv.load(File.join(__dir__, '.env'))

# Run database migrations on startup
require_relative 'app/services/migrator'
Services::Migrator.new.run!

require_relative 'app'
require_relative 'app/middleware/api_key_middleware'

# Rack middleware stack
use Middleware::ApiKeyMiddleware

run App
