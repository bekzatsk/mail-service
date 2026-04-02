# frozen_string_literal: true

require 'mysql2'

module Services
  class Migrator
    MIGRATIONS_PATH = File.expand_path('../../db/migrations', __dir__)

    def initialize
      # Connect without database — it may not exist yet
      @client = Mysql2::Client.new(
        host:     ENV.fetch('DB_HOST', '127.0.0.1'),
        port:     ENV.fetch('DB_PORT', '3306').to_i,
        username: ENV.fetch('DB_USER', 'root'),
        password: ENV.fetch('DB_PASS', ''),
        encoding: 'utf8mb4'
      )
      @db_name = ENV.fetch('DB_NAME', 'mail_service')
    end

    def run!
      create_database
      @client.query("USE `#{@db_name}`")
      create_migrations_table
      run_pending_migrations
    end

    private

    def create_database
      @client.query(
        "CREATE DATABASE IF NOT EXISTS `#{@db_name}` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci"
      )
      puts "[migrator] Database '#{@db_name}' ready"
    end

    def create_migrations_table
      @client.query(<<~SQL)
        CREATE TABLE IF NOT EXISTS schema_migrations (
          version VARCHAR(255) PRIMARY KEY,
          executed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
      SQL
    end

    def run_pending_migrations
      executed = @client.query('SELECT version FROM schema_migrations').map { |r| r['version'] }

      migration_files.each do |file|
        version = File.basename(file)
        next if executed.include?(version)

        puts "[migrator] Running #{version}..."
        sql = File.read(file)

        # Execute each statement separately (split on semicolons)
        sql.split(';').each do |statement|
          statement = statement.strip
          next if statement.empty?

          @client.query(statement)
        end

        # Mark as executed
        stmt = @client.prepare('INSERT INTO schema_migrations (version) VALUES (?)')
        stmt.execute(version)
        puts "[migrator] ✓ #{version}"
      end

      puts '[migrator] All migrations up to date'
    end

    def migration_files
      Dir.glob(File.join(MIGRATIONS_PATH, '*.sql')).sort
    end
  end
end
