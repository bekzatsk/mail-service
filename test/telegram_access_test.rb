# frozen_string_literal: true

# Who may touch which bot.
#
# A Telegram bot is owned by the organization of the client that connected it,
# and may be granted to other organizations. The split is deliberate:
#
#   owner only   the bot row — token, transport, deletion, and the grants
#   shared       everything hanging off it — chats, routes, commands,
#                message history, sending
#
# Two ways that boundary breaks in practice, and this file asserts against
# both. A new query that joins `client_telegram_bots` without the grant table
# quietly hides granted bots from the organization that was given them. An
# owner-only route that reaches for `accessible_bot` instead of `owner_bot`
# hands a borrower the token-rotation button.
#
#   ruby test/telegram_access_test.rb

$LOAD_PATH.unshift File.expand_path('support', __dir__)

require 'json'
require 'mysql2' # resolves to test/support/mysql2.rb
require_relative 'support/assertions'

ENV['ENCRYPTION_KEY'] ||= '0' * 64

require_relative '../app/handlers/telegram_handler'

# Every query the handler makes lands here instead of a database. Stubbed after
# the require so it replaces the real Services::Database.query.
QUERIES = []

# Whether a bot lookup finds anything. The two halves of this file want
# opposite answers: the "which lookup" checks want a miss, so the method stops
# at its 404 instead of running on into encryption and Telegram; the SQL-shape
# checks want a hit, so the queries downstream of it are actually emitted.
$bot_rows = [{ 'id' => 11 }, { 'id' => 12 }]

module Services
  class Database
    def self.query(sql, params = [])
      QUERIES << [sql, params]
      sql.include?('FROM client_telegram_bots b') ? $bot_rows : []
    end
  end
end

# The handler only ever reads these two off a request.
module Rack
  class Request
    def initialize(params = {}, body = '{}')
      @params = params
      @body = body
    end

    def params = @params
    def body = StringIO.new(@body)
  end
end
require 'stringio'

HANDLER = Handlers::TelegramHandler.new
CLIENT  = { 'id' => 1, 'organization_id' => 7 }.freeze

def record
  QUERIES.clear
  yield
  QUERIES.dup
end

# ── Which lookup each entry point trusts ────────────────────────────────────
#
# Asserted by watching which helper gets called rather than by inspecting SQL,
# because this is the decision that matters: owner_bot excludes grants by
# construction, accessible_bot includes them.

$access_calls = []
HANDLER.singleton_class.prepend(Module.new do
  def owner_bot(client, bot_id)
    $access_calls << :owner_bot
    super
  end

  def accessible_bot(client, bot_id)
    $access_calls << :accessible_bot
    super
  end
end)

# The lookup misses, so each method returns its 404 and never reaches the work
# behind it — this asks which door it knocked on, nothing more.
def lookup_used
  $access_calls.clear
  $bot_rows = []
  yield
  $access_calls.first
ensure
  $bot_rows = [{ 'id' => 11 }, { 'id' => 12 }]
end

puts 'Owner-only — the bot row itself'
{
  'PATCH  /telegram/bots/:id'          => -> { HANDLER.update_bot(Rack::Request.new, CLIENT, 11) },
  'DELETE /telegram/bots/:id'          => -> { HANDLER.delete_bot(CLIENT, 11) },
  'POST   /telegram/bots/:id/webhook'  => -> { HANDLER.enable_webhook(Rack::Request.new, CLIENT, 11) },
  'DELETE /telegram/bots/:id/webhook'  => -> { HANDLER.disable_webhook(CLIENT, 11) },
  'GET    /telegram/bots/:id/webhook'  => -> { HANDLER.webhook_info(CLIENT, 11) },
  'GET    /telegram/bots/:id/grants'   => -> { HANDLER.list_grants(CLIENT, 11) },
  'POST   /telegram/bots/:id/grants'   => -> { HANDLER.create_grant(Rack::Request.new, CLIENT, 11) },
  'DELETE /telegram/bots/:id/grants/:g' => -> { HANDLER.delete_grant(CLIENT, 11, 4) }
}.each do |label, call|
  Assertions.check("#{label} uses owner_bot", lookup_used(&call), :owner_bot)
end

puts "\nShared — everything hanging off the bot"
{
  'GET  /telegram/bots/:id'                 => -> { HANDLER.show_bot(CLIENT, 11) },
  'POST /telegram/bots/:id/sync-commands'   => -> { HANDLER.sync_commands(CLIENT, 11) },
  'GET  /telegram/chats?botId='             => -> { HANDLER.list_chats(Rack::Request.new({ 'botId' => '11' }), CLIENT) },
  'GET  /telegram/commands?botId='          => -> { HANDLER.list_commands(Rack::Request.new({ 'botId' => '11' }), CLIENT) }
}.each do |label, call|
  Assertions.check("#{label} uses accessible_bot", lookup_used(&call), :accessible_bot)
end

# ── No read of a bot may forget the grant table ─────────────────────────────

puts "\nEvery shared read joins telegram_bot_grants"
{
  'GET  /telegram/bots'     => -> { HANDLER.list_bots(CLIENT) },
  'GET  /telegram/routes'   => -> { HANDLER.list_routes(CLIENT) },
  'GET  /telegram/chats'    => -> { HANDLER.list_chats(Rack::Request.new, CLIENT) },
  'GET  /telegram/commands' => -> { HANDLER.list_commands(Rack::Request.new, CLIENT) },
  'PATCH /telegram/chats/:id' => -> { HANDLER.update_chat(Rack::Request.new, CLIENT, 3) },
  'DELETE /telegram/chats/:id' => -> { HANDLER.delete_chat(CLIENT, 3) }
}.each do |label, call|
  sqls = record(&call).map(&:first)
  bot_reads = sqls.select { |sql| sql.include?('client_telegram_bots') }
  Assertions.check("#{label} reads bots at all", bot_reads.empty?, false)
  Assertions.check("#{label} every bot read carries the grant join",
                   bot_reads.all? { |sql| sql.include?('telegram_bot_grants') }, true)
end

puts "\nOwner lookups deliberately do NOT see grants"
sqls = record { HANDLER.send(:owner_bot, CLIENT, 11) }.map(&:first)
Assertions.check('owner_bot never joins telegram_bot_grants',
                 sqls.any? { |sql| sql.include?('telegram_bot_grants') }, false)
Assertions.check('owner_bot filters on the owning organization',
                 sqls.first.include?('oc.organization_id = ?'), true)

# ── Message history follows bot access, not the sending client ──────────────

puts "\nMessage history is scoped by reachable bot, not by client_id"
sqls = record { HANDLER.list_messages(Rack::Request.new, CLIENT) }.map(&:first)
msg_sql = sqls.find { |sql| sql.include?('FROM telegram_messages') }
Assertions.check('list_messages filters on bot_id IN (...)', msg_sql.include?('bot_id IN ('), true)
Assertions.check('list_messages does not fall back to client_id', msg_sql.include?('client_id'), false)

sqls = record { HANDLER.show_message(CLIENT, 42) }.map(&:first)
msg_sql = sqls.find { |sql| sql.include?('FROM telegram_messages') }
Assertions.check('show_message filters on bot_id IN (...)', msg_sql.include?('bot_id IN ('), true)
Assertions.check('show_message does not fall back to client_id', msg_sql.include?('client_id'), false)

# A botId the caller cannot reach must intersect to nothing rather than widen.
sqls = record { HANDLER.list_messages(Rack::Request.new({ 'botId' => '99' }), CLIENT) }.map(&:first)
msg_sql = sqls.find { |sql| sql.include?('FROM telegram_messages') }
Assertions.check('an explicit botId narrows the reachable set, never replaces it',
                 msg_sql.include?('bot_id IN (') && msg_sql.include?('AND bot_id = ?'), true)

# ── Placeholders and binds must agree ───────────────────────────────────────
#
# The access fragments are interpolated strings carrying their own "?", so an
# added condition is easy to get wrong — and a mismatch is a runtime 500 on a
# path with no database in CI to catch it.

puts "\nEvery query binds as many values as it has placeholders"
all = record do
  HANDLER.list_bots(CLIENT)
  HANDLER.show_bot(CLIENT, 11)
  HANDLER.list_routes(CLIENT)
  HANDLER.list_chats(Rack::Request.new, CLIENT)
  HANDLER.list_commands(Rack::Request.new, CLIENT)
  HANDLER.list_messages(Rack::Request.new, CLIENT)
  HANDLER.show_message(CLIENT, 42)
  HANDLER.send(:resolve_bot, CLIENT, {})
  HANDLER.send(:resolve_bot, CLIENT, { 'botName' => 'main' })
  HANDLER.send(:accessible_bot, CLIENT, 11)
  HANDLER.send(:find_client_chat, CLIENT, 3)
  HANDLER.send(:find_client_command, CLIENT, 4)
  HANDLER.send(:load_grants, [11, 12])
end
mismatched = all.reject { |sql, params| sql.count('?') == params.length }
Assertions.check("all #{all.length} queries bind cleanly",
                 mismatched.map { |sql, _| sql.gsub(/\s+/, ' ')[0, 60] }, [])

Assertions.report('telegram access')
