# frozen_string_literal: true

require 'sinatra/base'
require 'json'

require_relative 'app/handlers/organization_handler'
require_relative 'app/handlers/config_handler'
require_relative 'app/handlers/mail_handler'
require_relative 'app/handlers/telegram_handler'

class App < Sinatra::Base
  configure do
    set :show_exceptions, false
    set :raise_errors, false
  end

  before do
    content_type :json
  end

  # ── Handlers ────────────────────────────────────────────────────────
  organization_handler = Handlers::OrganizationHandler.new
  config_handler       = Handlers::ConfigHandler.new
  mail_handler         = Handlers::MailHandler.new
  telegram_handler     = Handlers::TelegramHandler.new

  # ── Routes: Organizations (master key for POST, public for GET) ────

  post '/organizations' do
    status_code, headers, body = organization_handler.create(request)
    status status_code
    headers.each { |k, v| response[k] = v }
    body.first
  end

  get '/organizations' do
    status_code, headers, body = organization_handler.list
    status status_code
    headers.each { |k, v| response[k] = v }
    body.first
  end

  get '/organizations/:id' do
    status_code, headers, body = organization_handler.show(params['id'].to_i)
    status status_code
    headers.each { |k, v| response[k] = v }
    body.first
  end

  # ── Routes: Client config (master key required) ────────────────────

  # Test SMTP connection without saving
  post '/config/test' do
    status_code, headers, body = config_handler.test(request)
    status status_code
    headers.each { |k, v| response[k] = v }
    body.first
  end

  # Register new client SMTP config
  post '/config' do
    status_code, headers, body = config_handler.call(request)
    status status_code
    headers.each { |k, v| response[k] = v }
    body.first
  end

  # ── Routes: Mail (protected — X-Api-Key via middleware) ────────────

  post '/send' do
    client = env['mail_service.client']
    status_code, headers, body = mail_handler.send_mail(request, client)
    status status_code
    headers.each { |k, v| response[k] = v }
    body.first
  end

  get '/logs' do
    client = env['mail_service.client']
    status_code, headers, body = mail_handler.logs(client)
    status status_code
    headers.each { |k, v| response[k] = v }
    body.first
  end

  # ── Routes: Telegram (client key required via middleware) ──────────

  # Bots
  post '/telegram/bots/test' do
    client = env['mail_service.client']
    status_code, headers, body = telegram_handler.test_bot(request, client)
    status status_code
    headers.each { |k, v| response[k] = v }
    body.first
  end

  post '/telegram/bots' do
    client = env['mail_service.client']
    status_code, headers, body = telegram_handler.create_bot(request, client)
    status status_code
    headers.each { |k, v| response[k] = v }
    body.first
  end

  get '/telegram/bots' do
    client = env['mail_service.client']
    status_code, headers, body = telegram_handler.list_bots(client)
    status status_code
    headers.each { |k, v| response[k] = v }
    body.first
  end

  get '/telegram/bots/:id' do
    client = env['mail_service.client']
    status_code, headers, body = telegram_handler.show_bot(client, params['id'].to_i)
    status status_code
    headers.each { |k, v| response[k] = v }
    body.first
  end

  patch '/telegram/bots/:id' do
    client = env['mail_service.client']
    status_code, headers, body = telegram_handler.update_bot(request, client, params['id'].to_i)
    status status_code
    headers.each { |k, v| response[k] = v }
    body.first
  end

  delete '/telegram/bots/:id' do
    client = env['mail_service.client']
    status_code, headers, body = telegram_handler.delete_bot(client, params['id'].to_i)
    status status_code
    headers.each { |k, v| response[k] = v }
    body.first
  end

  post '/telegram/bots/:id/sync-commands' do
    client = env['mail_service.client']
    status_code, headers, body = telegram_handler.sync_commands(client, params['id'].to_i)
    status status_code
    headers.each { |k, v| response[k] = v }
    body.first
  end

  # Messages
  post '/telegram/messages' do
    client = env['mail_service.client']
    status_code, headers, body = telegram_handler.send_message(request, client)
    status status_code
    headers.each { |k, v| response[k] = v }
    body.first
  end

  get '/telegram/messages' do
    client = env['mail_service.client']
    status_code, headers, body = telegram_handler.list_messages(request, client)
    status status_code
    headers.each { |k, v| response[k] = v }
    body.first
  end

  get '/telegram/messages/:id' do
    client = env['mail_service.client']
    status_code, headers, body = telegram_handler.show_message(client, params['id'].to_i)
    status status_code
    headers.each { |k, v| response[k] = v }
    body.first
  end

  # Chats
  post '/telegram/chats' do
    client = env['mail_service.client']
    status_code, headers, body = telegram_handler.create_chat(request, client)
    status status_code
    headers.each { |k, v| response[k] = v }
    body.first
  end

  get '/telegram/chats' do
    client = env['mail_service.client']
    status_code, headers, body = telegram_handler.list_chats(request, client)
    status status_code
    headers.each { |k, v| response[k] = v }
    body.first
  end

  delete '/telegram/chats/:id' do
    client = env['mail_service.client']
    status_code, headers, body = telegram_handler.delete_chat(client, params['id'].to_i)
    status status_code
    headers.each { |k, v| response[k] = v }
    body.first
  end

  # Commands
  post '/telegram/commands' do
    client = env['mail_service.client']
    status_code, headers, body = telegram_handler.create_command(request, client)
    status status_code
    headers.each { |k, v| response[k] = v }
    body.first
  end

  get '/telegram/commands' do
    client = env['mail_service.client']
    status_code, headers, body = telegram_handler.list_commands(request, client)
    status status_code
    headers.each { |k, v| response[k] = v }
    body.first
  end

  patch '/telegram/commands/:id' do
    client = env['mail_service.client']
    status_code, headers, body = telegram_handler.update_command(request, client, params['id'].to_i)
    status status_code
    headers.each { |k, v| response[k] = v }
    body.first
  end

  delete '/telegram/commands/:id' do
    client = env['mail_service.client']
    status_code, headers, body = telegram_handler.delete_command(client, params['id'].to_i)
    status status_code
    headers.each { |k, v| response[k] = v }
    body.first
  end

  # 404 fallback
  not_found do
    JSON.generate(error: 'Not found')
  end

  # Global error handler
  error do
    JSON.generate(error: 'Internal server error', details: env['sinatra.error']&.message)
  end
end
