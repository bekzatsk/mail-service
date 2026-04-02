# frozen_string_literal: true

require 'sinatra/base'
require 'json'

require_relative 'app/handlers/organization_handler'
require_relative 'app/handlers/config_handler'
require_relative 'app/handlers/mail_handler'

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

  # 404 fallback
  not_found do
    JSON.generate(error: 'Not found')
  end

  # Global error handler
  error do
    JSON.generate(error: 'Internal server error', details: env['sinatra.error']&.message)
  end
end
