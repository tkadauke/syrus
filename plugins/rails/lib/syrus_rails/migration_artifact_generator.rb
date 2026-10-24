require "digest"
require "fileutils"
require "json"
require "securerandom"
require "tmpdir"
require "uri"
require "yaml"

module SyrusRails
  class MigrationArtifactGenerator
    TIMEOUT = 120
    RESULT_PREFIX = "SYRUS_MIGRATION_ARTIFACT="
    LOCAL_HOSTS = %w[localhost 127.0.0.1 ::1].freeze

    class GenerationError < StandardError
      attr_reader :stage

      def initialize(message, stage: "setup")
        @stage = stage
        super(message)
      end
    end
    class DisposableDatabaseUnavailable < GenerationError; end

    def initialize(workspace:, workflow:, git: GitRunner.new(workflow: workflow), runner: ProcessRunner)
      @workspace = Pathname.new(workspace)
      @workflow = workflow
      @git = git
      @runner = runner
    end

    def generate(file_path)
      base = @git.run("merge-base", "HEAD", WorkflowWorkspace.new(@workflow).base_ref, chdir: @workspace.to_s).strip
      migrations = added_migrations(base)
      requested = clean_relative_path(file_path)
      raise GenerationError, "migration is not newly added relative to #{base.first(12)}: #{requested}" unless migrations.include?(requested)

      execute(base, migrations).fetch(requested)
    rescue GenerationError => e
      error_payload(file_path, "setup", e.message)
    rescue StandardError => e
      error_payload(file_path, "setup", "#{e.class}: #{e.message}")
    end

    private

    def added_migrations(base)
      @git.run("diff", "--name-only", "--diff-filter=A", base, "--", "db/migrate/*.rb", chdir: @workspace.to_s)
        .lines.map(&:strip).reject(&:empty?).sort
    end

    def clean_relative_path(path)
      value = Pathname.new(path.to_s).cleanpath.to_s
      raise GenerationError, "migration path must be under db/migrate" unless value.match?(%r{\Adb/migrate/\d+_[^/]+\.rb\z})
      value
    end

    def execute(base, migrations)
      schema_kind, schema = base_schema(base)

      Dir.mktmpdir("syrus-migration-artifact") do |dir|
        schema_path = File.join(dir, schema_kind == :ruby ? "schema.rb" : "structure.sql")
        runner_path = File.join(dir, "runner.rb")
        File.write(schema_path, schema)
        File.write(runner_path, runner_source)
        database_urls = isolated_database_urls(dir)
        env = process_env(database_urls, schema_path, schema_kind, migrations)
        mounts = ProcessRunner.mounts(@workspace.to_s, read_write: @workspace.to_s, read_only: dir)
        capture = nil
        cleanup = nil
        begin
          capture = process_capture(env:, mounts:, command: execution_command, timeout: TIMEOUT, display_command: "generate Rails migration artifacts")
        ensure
          begin
            cleanup = process_capture(env:, mounts:, command: cleanup_command, timeout: 30, display_command: "drop Rails migration artifact databases")
          rescue StandardError => e
            raise GenerationError.new("cleanup failed to start: #{e.class}: #{e.message}", stage: "cleanup")
          end
        end
        unless cleanup.result.success?
          detail = cleanup.result.timed_out? ? "timed out after 30s" : cleanup.stderr.to_s.lines.last(12).join.strip
          raise GenerationError.new("cleanup failed: #{detail.presence || "exit #{cleanup.result.exit_status}"}", stage: "cleanup")
        end
        unless capture.result.success?
          detail = capture.result.timed_out? ? "timed out after #{TIMEOUT}s" : capture.stderr.to_s.lines.last(12).join.strip
          raise GenerationError.new("migration execution failed: #{detail.presence || "exit #{capture.result.exit_status}"}", stage: "execution")
        end
        line = capture.stdout.lines.reverse.find { |candidate| candidate.start_with?(RESULT_PREFIX) }
        raise GenerationError.new("migration introspection produced no result", stage: "introspection") unless line
        begin
          JSON.parse(line.delete_prefix(RESULT_PREFIX)).transform_keys { |key| "db/migrate/#{key}" }
        rescue JSON::ParserError => e
          raise GenerationError.new("migration introspection returned invalid JSON: #{e.message}", stage: "introspection")
        end
      ensure
        Array(database_urls&.values).each { |url| FileUtils.rm_f(URI.parse(url).path) if url.start_with?("sqlite3:") }
      end
    rescue DisposableDatabaseUnavailable => e
      fallback(base, migrations, e.message)
    rescue GenerationError => e
      migrations.index_with { |path| error_payload(path, e.stage, e.message) }
    end

    def execution_command
      schema_task = database_names.length > 1 ? "db:schema:load:primary" : "db:schema:load"
      [ "bash", "-c", "bin/rails db:create #{schema_task} && bin/rails runner \"$SYRUS_ARTIFACT_RUNNER\"" ]
    end

    def cleanup_command
      [ "bash", "-c", "DISABLE_DATABASE_ENVIRONMENT_CHECK=1 bin/rails db:drop" ]
    end

    def process_capture(env:, mounts:, command:, timeout:, display_command:)
      @runner.new(
        env:, command:, mounts:, network: "grader", timeout:, kind: "artifact", workflow: @workflow,
        display_command:
      ).capture
    end

    def base_schema(base)
      %w[db/schema.rb db/structure.sql].each do |path|
        content = @git.run("show", "#{base}:#{path}", chdir: @workspace.to_s)
        return [ path.end_with?(".rb") ? :ruby : :structure, content ]
      rescue GitRunner::GitError
        next
      end
      raise GenerationError, "base revision has neither db/schema.rb nor db/structure.sql"
    end

    def isolated_database_url(dir)
      isolated_database_urls(dir).fetch("primary")
    end

    def isolated_database_urls(dir)
      adapter = configured_adapter
      nonce = SecureRandom.hex(12)
      if adapter.match?(/sqlite/i)
        return database_names.index_with { |name| "sqlite3:#{File.join(dir, "artifact-#{nonce}-#{name}.sqlite3")}" }
      end

      template = ENV["SYRUS_RAILS_ARTIFACT_DATABASE_URL"].presence
      raise DisposableDatabaseUnavailable, "#{adapter} artifact execution requires SYRUS_RAILS_ARTIFACT_DATABASE_URL" unless template
      uri = URI.parse(template)
      raise GenerationError, "artifact database target must use the repository adapter" unless uri.scheme.to_s.include?(adapter.sub("ql", ""))
      raise GenerationError, "artifact database target must be local" unless LOCAL_HOSTS.include?(uri.host)
      identity = Digest::SHA256.hexdigest([ @workspace.realpath, Process.pid, nonce ].join(":"))[0, 20]
      database_names.index_with do |name|
        isolated = uri.dup
        isolated.path = "/syrus_artifact_#{identity}_#{name}"
        isolated.to_s
      end
    rescue URI::InvalidURIError => e
      raise GenerationError, "invalid artifact database URL: #{e.message}"
    end

    def database_configuration
      path = @workspace.join("config/database.yml")
      raw = path.read.gsub(/<%=.*?%>/m, "")
      YAML.safe_load(raw, aliases: true) || {}
    rescue Psych::Exception => e
      raise GenerationError, "cannot read database configuration: #{e.message}"
    end

    def configured_adapter
      config = database_configuration
      development = config["development"]
      primary = development.is_a?(Hash) && development.values.all?(Hash) ? development["primary"] : development
      primary&.fetch("adapter", nil) || config.dig("default", "adapter") || raise(GenerationError, "cannot determine database adapter")
    end

    def database_names
      development = database_configuration["development"]
      names = if development.is_a?(Hash) && development.values.all?(Hash)
        development.keys
      else
        [ "primary" ]
      end
      names.each do |name|
        raise GenerationError, "unsafe database configuration name #{name.inspect}" unless name.match?(/\A[a-zA-Z][a-zA-Z0-9_]*\z/)
      end
      names
    end

    def process_env(urls, schema_path, schema_kind, migrations)
      primary_url = urls.fetch("primary")
      env = {
        "RAILS_ENV" => "development", "DATABASE_URL" => primary_url,
        "SYRUS_ARTIFACT_SANDBOX" => "1", "SYRUS_ARTIFACT_SCHEMA" => schema_path,
        "SYRUS_ARTIFACT_MIGRATIONS" => JSON.generate(migrations.map { |path| @workspace.join(path).to_s }),
        "SYRUS_ARTIFACT_RUNNER" => File.join(File.dirname(schema_path), "runner.rb"),
        "SCHEMA" => schema_path, "SCHEMA_FORMAT" => schema_kind == :ruby ? "ruby" : "sql",
        "SYRUS_ARTIFACT_DATABASES" => JSON.generate(urls.values.map { |url| URI.parse(url).path.delete_prefix("/") })
      }
      urls.each { |name, url| env["#{name.upcase}_DATABASE_URL"] = url }
      env
    end

    def fallback(base, migrations, reason)
      kind, base_content = base_schema(base)
      head = @workspace.join(kind == :ruby ? "db/schema.rb" : "db/structure.sql")
      raise GenerationError, "#{reason}; schema-dump fallback unavailable" unless head.file?
      payload = if kind == :ruby
        catalog_payload(File.basename(migrations.last, ".rb"), SchemaParser.new(base_content).parse[:tables], SchemaParser.parse(head)[:tables])
      else
        structure_payload(File.basename(migrations.last, ".rb"), base_content, head.read)
      end
      payload[:status] = "cumulative_fallback"
      payload[:cumulative] = true
      payload[:message] = "Cumulative schema diff for #{migrations.length} migration(s); per-migration attribution unavailable: #{reason}"
      migrations.index_with { payload }
    rescue StandardError => e
      migrations.index_with { |path| error_payload(path, "fallback", "#{reason}; #{e.message}") }
    end

    def structure_payload(name, before, after)
      before_statements = normalize_structure(before)
      after_statements = normalize_structure(after)
      {
        migration_name: name,
        before: { structure: before_statements - after_statements },
        after: { structure: after_statements - before_statements }
      }
    end

    def normalize_structure(content)
      content.lines
        .reject { |line| line.lstrip.start_with?("--") }
        .join
        .split(/;\s*(?:\n|\z)/)
        .map { |statement| statement.gsub(/\s+/, " ").strip }
        .reject { |statement| statement.empty? || statement.match?(/schema_migrations/i) }
    end

    def catalog_payload(name, before, after)
      names = (before.map { |table| table[:name] } | after.map { |table| table[:name] }).select do |table_name|
        before.find { |table| table[:name] == table_name } != after.find { |table| table[:name] == table_name }
      end
      {
        migration_name: name, status: names.empty? ? "no_schema_changes" : "success",
        before: { tables: before.select { |table| names.include?(table[:name]) } },
        after: { tables: after.select { |table| names.include?(table[:name]) } }
      }
    end

    def error_payload(path, stage, message)
      { migration_name: File.basename(path.to_s, ".rb"), status: "error", stage: stage, message: message }
    end

    def runner_source
      <<~'RUBY'
        require "json"
        abort "artifact sandbox marker missing" unless ENV["SYRUS_ARTIFACT_SANDBOX"] == "1"
        allowed_databases = JSON.parse(ENV.fetch("SYRUS_ARTIFACT_DATABASES"))
        configured = ActiveRecord::Base.configurations.configs_for(env_name: Rails.env)
        unsafe = configured.reject { |config| allowed_databases.include?(config.database.to_s.delete_prefix("/")) }
        abort "artifact sandbox has non-isolated database configurations: #{unsafe.map(&:name).join(', ')}" if unsafe.any?
        ActiveRecord::Base.establish_connection(ENV.fetch("DATABASE_URL"))
        connection = ActiveRecord::Base.connection
        ignored = %w[ar_internal_metadata schema_migrations]
        snapshot = lambda do
          connection.schema_cache.clear!
          connection.tables.sort.reject { |name| ignored.include?(name) }.map do |table|
            checks = connection.respond_to?(:check_constraints) ? connection.check_constraints(table).map { |c| { name: c.name, expression: c.expression } } : []
            {
              name: table,
              columns: connection.columns(table).map { |c| { name: c.name, type: c.type.to_s, sql_type: c.sql_type, limit: c.limit, precision: c.precision, scale: c.scale, nullable: c.null, default: c.default, default_function: c.default_function, collation: c.collation }.compact },
              indexes: connection.indexes(table).map { |i| { name: i.name, columns: i.columns, unique: i.unique, where: i.where }.compact }.sort_by { |i| i[:name] },
              foreign_keys: connection.foreign_keys(table).map { |f| { name: f.name, from_column: f.column, to_table: f.to_table, to_column: f.primary_key }.compact }.sort_by { |f| f[:name].to_s },
              check_constraints: checks.sort_by { |c| c[:name].to_s }
            }
          end
        end
        results = {}
        ENV.fetch("SYRUS_ARTIFACT_MIGRATIONS").then { |json| JSON.parse(json) }.each do |path|
          before = snapshot.call
          version = File.basename(path).split("_", 2).first.to_i
          proxy = ActiveRecord::MigrationContext.new([File.dirname(path)]).migrations.find { |m| m.version == version }
          raise "migration #{path} was not discoverable" unless proxy
          proxy.migrate(:up)
          after = snapshot.call
          names = (before.map { |table| table[:name] } | after.map { |table| table[:name] }).select { |name| before.find { |table| table[:name] == name } != after.find { |table| table[:name] == name } }
          results[File.basename(path)] = { migration_name: proxy.name, status: names.empty? ? "no_schema_changes" : "success", before: { tables: before.select { |table| names.include?(table[:name]) } }, after: { tables: after.select { |table| names.include?(table[:name]) } } }
        end
        puts "SYRUS_MIGRATION_ARTIFACT=#{JSON.generate(results)}"
      RUBY
    end
  end
end
