require "json"
require "digest"
require "uri"
require "yaml"

module SyrusRails
  class PreviewProvider
    RAILS_HEALTH_ROUTE_MARKER = "rails/health#show"

    def detect?(repo_path)
      @repo_path = repo_path

      File.exist?(File.join(repo_path, "Gemfile")) &&
        File.exist?(File.join(repo_path, "config", "application.rb")) &&
        File.exist?(File.join(repo_path, "bin", "rails"))
    end

    def start_command(port:)
      [
        "mkdir -p log tmp/pids",
        vite_start_fragment,
        "exec bin/rails server -p #{port} -b 0.0.0.0 -e development"
      ].compact.join(" && ")
    end

    def seed_command
      "bin/rails db:create db:migrate db:seed"
    end

    def env_for(key:)
      return {} unless postgresql?

      { "DATABASE_URL" => isolated_postgresql_url(key) }
    end

    def cleanup_command
      return unless postgresql?

      "for attempt in 1 2 3 4 5; do DISABLE_DATABASE_ENVIRONMENT_CHECK=1 bin/rails db:drop && exit 0; sleep 1; done; exit 1"
    end

    def setup_commands
      commands = [
        "bundle config set --local path vendor/bundle",
        "bundle install --jobs 4",
        "if [ -f package-lock.json ]; then npm ci; elif [ -f pnpm-lock.yaml ]; then corepack enable && pnpm install --frozen-lockfile; elif [ -f yarn.lock ]; then corepack enable && yarn install --frozen-lockfile; elif [ -f bun.lockb ] || [ -f bun.lock ]; then bun install --frozen-lockfile; fi"
      ]
      commands << postgresql_readiness_command if postgresql?
      commands
    end

    # "/up" only exists on apps generated from Rails' post-7.1 default
    # template (`get "up" => "rails/health#show"` in config/routes.rb). Older
    # or hand-rolled apps without that route fall back to the base interface's
    # "/" default, matching Django::PreviewProvider's documented convention.
    def health_check_path
      rails_health_route? ? "/up" : "/"
    end

    def log_paths
      ["log/development.log", "log/vite.log"]
    end

    def env
      {
        "RAILS_ENV" => "development",
        "SEARCH_DATABASE_PATH" => "storage/preview_search.sqlite3",
        "VITE_RUBY_SKIP_PROXY" => "false"
      }
    end

    def unset_env
      %w[
        DATABASE_URL
        CACHE_DATABASE_URL
        QUEUE_DATABASE_URL
        CABLE_DATABASE_URL
        DB_HOST
        SYRUS_DATABASE_PASSWORD
        SYRUS_SQLITE
      ]
    end

    private

    def postgresql?
      development_adapter.to_s.match?(/postgres/i)
    end

    def development_adapter
      return @development_adapter if defined?(@development_adapter)

      path = File.join(@repo_path.to_s, "config", "database.yml")
      @development_adapter = if File.exist?(path)
        raw = File.read(path).gsub(/<%=.*?%>/m, "__SYRUS_ERB__")
        config = YAML.safe_load(raw, aliases: true) || {}
        config.dig("development", "adapter") || config.dig("default", "adapter")
      end
    rescue StandardError
      @development_adapter = File.read(path)[/^\s*adapter:\s*["']?([^\s"']+)/, 1]
    end

    def postgresql_readiness_command
      %(ruby -ruri -rsocket -e 'u=URI(ENV.fetch("DATABASE_URL")); deadline=Process.clock_gettime(Process::CLOCK_MONOTONIC)+30; begin; TCPSocket.new(u.host,u.port||5432).close; rescue SystemCallError,SocketError; raise "PostgreSQL preview infrastructure was not ready within 30 seconds" if Process.clock_gettime(Process::CLOCK_MONOTONIC)>=deadline; sleep 1; retry; end')
    end

    def isolated_postgresql_url(key)
      configured = ENV["SYRUS_RAILS_PREVIEW_POSTGRES_URL"].presence
      unless configured
        raise "Rails preview uses PostgreSQL, but SYRUS_RAILS_PREVIEW_POSTGRES_URL is not configured on the preview runtime"
      end

      uri = URI.parse(configured)
      unless %w[postgres postgresql].include?(uri.scheme) && uri.host.present?
        raise "SYRUS_RAILS_PREVIEW_POSTGRES_URL must be a PostgreSQL URL with a host"
      end

      identity = [ File.realpath(@repo_path), key ].join(":")
      uri.path = "/syrus_preview_#{Digest::SHA256.hexdigest(identity).first(24)}"
      uri.to_s
    rescue URI::InvalidURIError
      raise "SYRUS_RAILS_PREVIEW_POSTGRES_URL must be a valid PostgreSQL URL"
    end

    def rails_health_route?
      return false unless @repo_path

      routes_file = File.join(@repo_path, "config", "routes.rb")
      File.exist?(routes_file) && File.read(routes_file).include?(RAILS_HEALTH_ROUTE_MARKER)
    end

    # Only launches `npm run dev` when package.json actually defines a `dev`
    # script — an unconditional launch just pollutes log/vite.log with
    # "Missing script" errors on repos that ship a package.json for other
    # tooling (linting, etc.) without a dev server.
    def vite_start_fragment
      return nil unless dev_script?

      "if [ -f package.json ]; then npm run dev > log/vite.log 2>&1 & fi"
    end

    def dev_script?
      return false unless @repo_path

      package_json = File.join(@repo_path, "package.json")
      return false unless File.exist?(package_json)

      data = JSON.parse(File.read(package_json))
      data.is_a?(Hash) && data["scripts"].is_a?(Hash) && data["scripts"].key?("dev")
    rescue JSON::ParserError
      false
    end
  end
end
