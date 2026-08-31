# frozen_string_literal: true

# Stand-in for the mysql2 gem so unit tests can load the middleware without a
# database or a bundle. `test/support` goes on $LOAD_PATH before the code under
# test runs, so its `require 'mysql2'` resolves here.
module Mysql2
  class Client
    def initialize(*); end

    def prepare(*)
      raise 'Mysql2 is stubbed in tests — stub Services::Database.query instead'
    end
  end
end
