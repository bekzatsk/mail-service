# frozen_string_literal: true

# Who may reach which route, with which key.
#
# This is the security boundary of the whole service: getting it wrong exposes
# every organization's mail log or every client's API key. It is cheap to assert
# and expensive to get wrong, so it is asserted on every push.
#
#   ruby test/middleware_routes_test.rb

$LOAD_PATH.unshift File.expand_path('support', __dir__)

require 'json'
require 'mysql2' # resolves to test/support/mysql2.rb
require_relative 'support/assertions'

# The middleware only ever touches these two Rack::Request methods.
module Rack
  class Request
    def initialize(env) = @env = env
    def request_method = @env['REQUEST_METHOD']
    def path = @env['PATH_INFO']
  end
end

require_relative '../app/middleware/api_key_middleware'

MASTER_KEY = 'master-key-for-tests'
CLIENT_KEY = 'client-key-for-tests'

# Only CLIENT_KEY resolves to a row; everything else looks like an unknown key.
module Services
  class Database
    def self.query(_sql, params = [])
      params.first == CLIENT_KEY ? [{ 'id' => 1, 'organization_id' => 7 }] : []
    end
  end
end

ENV['MASTER_API_KEY'] = MASTER_KEY

downstream = lambda do |env|
  body = "OK #{env['PATH_INFO']}"
  body += ' +client' if env['mail_service.client']
  [200, {}, [body]]
end
middleware = Middleware::ApiKeyMiddleware.new(downstream)

def request(middleware, method, path, key)
  env = { 'REQUEST_METHOD' => method, 'PATH_INFO' => path }
  env['HTTP_X_API_KEY'] = key if key
  middleware.call(env)
end

def expect(middleware, method, path, key, status)
  label = format('%-6s %-32s key=%s', method, path, key ? key.split('-').first : '(none)')
  actual, = request(middleware, method, path, key)
  Assertions.check(label, actual, status)
end

puts 'Public — the console\'s static assets, and nothing else'
expect(middleware, 'GET', '/',              nil, 200)
expect(middleware, 'GET', '/ui/',           nil, 200)
expect(middleware, 'GET', '/ui/js/app.js',  nil, 200)
expect(middleware, 'GET', '/favicon.ico',   nil, 200)

puts "\nMaster-only — organizations, client config, and the whole admin surface"
[
  ['GET',    '/organizations'],
  ['GET',    '/organizations/3'],
  ['POST',   '/organizations'],
  ['POST',   '/config'],
  ['POST',   '/config/test'],
  ['GET',    '/admin/stats'],
  ['GET',    '/admin/clients'],
  ['GET',    '/admin/logs'],
  ['PATCH',  '/admin/clients/1'],
  ['DELETE', '/admin/organizations/2'],
  ['POST',   '/admin/clients/1/rotate-key']
].each do |method, path|
  expect(middleware, method, path, nil,        401) # no key at all
  expect(middleware, method, path, 'nonsense', 403) # wrong key
  expect(middleware, method, path, CLIENT_KEY, 403) # a client key must not escalate
  expect(middleware, method, path, MASTER_KEY, 200)
end

puts "\nTelegram webhook — public by necessity, authenticated by secret token"
# Telegram cannot send our X-Api-Key. The middleware lets these through and the
# handler compares X-Telegram-Bot-Api-Secret-Token instead.
expect(middleware, 'POST', '/telegram/webhook/11', nil, 200)
expect(middleware, 'POST', '/telegram/webhook/11', 'nonsense', 200)
# Only POST, and only under that exact prefix. A near-miss must not inherit it.
expect(middleware, 'GET',    '/telegram/webhook/11', nil, 401)
expect(middleware, 'DELETE', '/telegram/webhook/11', nil, 401)
expect(middleware, 'POST',   '/telegram/webhookfoo', nil, 401)
expect(middleware, 'POST',   '/telegram/webhook',    nil, 401)

puts "\nClient-only — sending and the Telegram gateway"
[
  ['POST', '/send'],
  ['GET',  '/logs'],
  ['GET',  '/telegram/bots'],
  ['POST', '/telegram/messages'],
  ['GET',  '/telegram/commands']
].each do |method, path|
  expect(middleware, method, path, nil,        401)
  expect(middleware, method, path, 'nonsense', 403)
  expect(middleware, method, path, MASTER_KEY, 403) # master is not a client key
  expect(middleware, method, path, CLIENT_KEY, 200)
end

puts "\nThe authenticated client row reaches the app"
_, _, body = request(middleware, 'POST', '/send', CLIENT_KEY)
Assertions.check('client row injected as env[mail_service.client]', body.first.include?('+client'), true)

Assertions.report('middleware routes')
