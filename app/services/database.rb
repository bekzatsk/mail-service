# frozen_string_literal: true

require 'mysql2'

module Services
  class Database
    class << self
      def connection
        @connection ||= Mysql2::Client.new(
          host:     ENV.fetch('DB_HOST', '127.0.0.1'),
          port:     ENV.fetch('DB_PORT', '3306').to_i,
          database: ENV.fetch('DB_NAME', 'mail_service'),
          username: ENV.fetch('DB_USER', 'root'),
          password: ENV.fetch('DB_PASS', ''),
          encoding: 'utf8mb4',
          reconnect: true
        )
      end

      def query(sql, params = [])
        stmt = connection.prepare(sql)
        stmt.execute(*params)
      end
    end
  end
end
