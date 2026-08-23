require "json"

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

    def setup_commands
      [
        "bundle config set --local path vendor/bundle",
        "bundle install --jobs 4",
        "if [ -f package-lock.json ]; then npm ci; elif [ -f pnpm-lock.yaml ]; then corepack enable && pnpm install --frozen-lockfile; elif [ -f yarn.lock ]; then corepack enable && yarn install --frozen-lockfile; elif [ -f bun.lockb ] || [ -f bun.lock ]; then bun install --frozen-lockfile; fi"
      ]
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
