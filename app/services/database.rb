# frozen_string_literal: true

require 'mysql2'

module Services
  class Database
    class << self
      # One connection per thread, per process.
      #
      # Mysql2::Client is not safe to share between threads: the Puma request
      # threads and the Telegram polling threads all run queries, and two of
      # them on one socket interleave their protocol frames. Keying on the
      # thread keeps each query's result with the query that ran it, and
      # `last_id` meaningful. Keying on the pid as well means a connection
      # opened before Passenger forks is not reused — shared — by the child.
      def connection
        key = :"mail_service.db.#{Process.pid}"
        Thread.current[key] ||= Mysql2::Client.new(
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
