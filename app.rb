# frozen_string_literal: true

require 'sinatra/base'
require 'json'

require_relative 'app/handlers/organization_handler'
require_relative 'app/handlers/config_handler'
require_relative 'app/handlers/mail_handler'
require_relative 'app/handlers/telegram_handler'
require_relative 'app/handlers/admin_handler'

class App < Sinatra::Base
  UI_ROOT = File.join(__dir__, 'public', 'ui')

  configure do
    set :show_exceptions, false
    set :raise_errors, false
    set :static, true
    set :public_folder, File.join(__dir__, 'public')
  end

  before do
    content_type :json
  end

  helpers do
    # Handlers return a Rack triple; unpack it onto the Sinatra response.
    def emit(triple)
      status_code, headers, body = triple
      status status_code
      headers.each { |k, v| response[k] = v }
      body.first
    end
  end

  # ── Handlers ────────────────────────────────────────────────────────
  organization_handler = Handlers::OrganizationHandler.new
  config_handler       = Handlers::ConfigHandler.new
  mail_handler         = Handlers::MailHandler.new
  telegram_handler     = Handlers::TelegramHandler.new
  admin_handler        = Handlers::AdminHandler.new

  # ── Routes: Admin UI (static, served from public/ui) ────────────────

  get '/' do
    redirect '/ui/'
  end

  %w[/ui /ui/].each do |ui_path|
    get ui_path do
      send_file File.join(UI_ROOT, 'index.html'), type: :html
    end
  end

  # ── Routes: Organizations (master key for POST, public for GET) ────

  post '/organizations' do
    emit organization_handler.create(request)
  end

  get '/organizations' do
    emit organization_handler.list
  end

  get '/organizations/:id' do
    emit organization_handler.show(params['id'].to_i)
  end

  # ── Routes: Client config (master key required) ────────────────────

  # Test SMTP connection without saving
  post '/config/test' do
    emit config_handler.test(request)
  end

  # Register new client SMTP config
  post '/config' do
    emit config_handler.call(request)
  end

  # ── Routes: Admin panel backend (master key required) ──────────────

  get '/admin/stats' do
    emit admin_handler.stats
  end

  get '/admin/organizations' do
    emit admin_handler.list_organizations
  end

  patch '/admin/organizations/:id' do
    emit admin_handler.update_organization(request, params['id'].to_i)
  end

  delete '/admin/organizations/:id' do
    emit admin_handler.delete_organization(params['id'].to_i)
  end

  get '/admin/clients' do
    emit admin_handler.list_clients(request)
  end

  get '/admin/clients/:id' do
    emit admin_handler.show_client(params['id'].to_i)
  end

  patch '/admin/clients/:id' do
    emit admin_handler.update_client(request, params['id'].to_i)
  end

  delete '/admin/clients/:id' do
    emit admin_handler.delete_client(params['id'].to_i)
  end

  post '/admin/clients/:id/rotate-key' do
    emit admin_handler.rotate_client_key(params['id'].to_i)
  end

  post '/admin/clients/:id/test' do
    emit admin_handler.test_client(params['id'].to_i)
  end

  get '/admin/logs' do
    emit admin_handler.logs(request)
  end

  # ── Routes: Mail (protected — X-Api-Key via middleware) ────────────

  post '/send' do
    emit mail_handler.send_mail(request, env['mail_service.client'])
  end

  get '/logs' do
    emit mail_handler.logs(env['mail_service.client'])
  end

  # ── Routes: Telegram webhook (public — authenticated by secret token) ──

  # Telegram cannot send our X-Api-Key, so this route is public in the
  # middleware and authenticates on X-Telegram-Bot-Api-Secret-Token instead.
  post '/telegram/webhook/:bot_id' do
    emit telegram_handler.receive_webhook(request, params['bot_id'].to_i)
  end

  # ── Routes: Telegram (client key required via middleware) ──────────

  # Bots
  post '/telegram/bots/test' do
    emit telegram_handler.test_bot(request, env['mail_service.client'])
  end

  post '/telegram/bots' do
    emit telegram_handler.create_bot(request, env['mail_service.client'])
  end

  get '/telegram/bots' do
    emit telegram_handler.list_bots(env['mail_service.client'])
  end

  get '/telegram/bots/:id' do
    emit telegram_handler.show_bot(env['mail_service.client'], params['id'].to_i)
  end

  patch '/telegram/bots/:id' do
    emit telegram_handler.update_bot(request, env['mail_service.client'], params['id'].to_i)
  end

  delete '/telegram/bots/:id' do
    emit telegram_handler.delete_bot(env['mail_service.client'], params['id'].to_i)
  end

  post '/telegram/bots/:id/webhook' do
    emit telegram_handler.enable_webhook(request, env['mail_service.client'], params['id'].to_i)
  end

  get '/telegram/bots/:id/webhook' do
    emit telegram_handler.webhook_info(env['mail_service.client'], params['id'].to_i)
  end

  delete '/telegram/bots/:id/webhook' do
    emit telegram_handler.disable_webhook(env['mail_service.client'], params['id'].to_i)
  end

  post '/telegram/bots/:id/sync-commands' do
    emit telegram_handler.sync_commands(env['mail_service.client'], params['id'].to_i)
  end

  # Messages
  post '/telegram/messages' do
    emit telegram_handler.send_message(request, env['mail_service.client'])
  end

  get '/telegram/messages' do
    emit telegram_handler.list_messages(request, env['mail_service.client'])
  end

  get '/telegram/messages/:id' do
    emit telegram_handler.show_message(env['mail_service.client'], params['id'].to_i)
  end

  # Chats
  post '/telegram/chats' do
    emit telegram_handler.create_chat(request, env['mail_service.client'])
  end

  get '/telegram/chats' do
    emit telegram_handler.list_chats(request, env['mail_service.client'])
  end

  delete '/telegram/chats/:id' do
    emit telegram_handler.delete_chat(env['mail_service.client'], params['id'].to_i)
  end

  # Commands
  post '/telegram/commands' do
    emit telegram_handler.create_command(request, env['mail_service.client'])
  end

  get '/telegram/commands' do
    emit telegram_handler.list_commands(request, env['mail_service.client'])
  end

  patch '/telegram/commands/:id' do
    emit telegram_handler.update_command(request, env['mail_service.client'], params['id'].to_i)
  end

  delete '/telegram/commands/:id' do
    emit telegram_handler.delete_command(env['mail_service.client'], params['id'].to_i)
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
