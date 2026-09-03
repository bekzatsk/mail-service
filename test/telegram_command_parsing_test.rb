# frozen_string_literal: true

# Which inbound messages count as a command decides where an update is sent:
# a matched command goes to that command's handler, everything else to the bot's
# message handler. Getting it wrong routes a customer's question into a handler
# that expects a command, or drops a command into free-text handling.
#
# The parser is pure, so it is tested without a database or a bot.
#
#   ruby test/telegram_command_parsing_test.rb

$LOAD_PATH.unshift File.expand_path('support', __dir__)
require 'mysql2' # stub, so requiring the processor does not need the gem
require_relative '../app/services/telegram_update_processor'
require_relative 'support/assertions'

P = Services::TelegramUpdateProcessor
check = Assertions.method(:check)

puts 'Commands'
check.call('bare command', P.parse_command('/status'), ['status', ''])
check.call('command with args', P.parse_command('/order 148'), ['order', '148'])
check.call('args keep their spacing', P.parse_command('/echo  a  b'), ['echo', 'a  b'])
check.call('multiline args', P.parse_command("/note line1\nline2"), ['note', "line1\nline2"])
# Telegram appends @botname in groups; the command is the same command.
check.call('addressed to the bot', P.parse_command('/status@acme_support_bot'), ['status', ''])
check.call('addressed, with args', P.parse_command('/order@acme_bot 148'), ['order', '148'])
check.call('case is normalised', P.parse_command('/STATUS'), ['status', ''])
check.call('underscores and digits', P.parse_command('/get_order_2'), ['get_order_2', ''])

puts "\nNot commands — these must reach the message handler instead"
check.call('plain text', P.parse_command('привет, где мой заказ?'), nil)
check.call('empty string', P.parse_command(''), nil)
check.call('nil', P.parse_command(nil), nil)
# A slash that names nothing is not a command; it is text that starts with "/".
check.call('lone slash', P.parse_command('/'), nil)
check.call('slash then space', P.parse_command('/ status'), nil)
check.call('a path, not a command', P.parse_command('/some/path'), nil)
check.call('slash not at the start', P.parse_command('see /status'), nil)
check.call('illegal characters', P.parse_command('/пример'), nil)
# 32 is Telegram's limit; 33 is not a command.
check.call('32 characters is a command', P.parse_command("/#{'a' * 32}"), ['a' * 32, ''])
check.call('33 characters is not', P.parse_command("/#{'a' * 33}"), nil)

Assertions.report('telegram command parsing')
