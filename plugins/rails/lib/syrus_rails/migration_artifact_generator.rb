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

    class GenerationError < StandardError; end
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
      return fallback(base, migrations, "base revision uses db/structure.sql") if schema_kind == :structure

      Dir.mktmpdir("syrus-migration-artifact") do |dir|
        schema_path = File.join(dir, "schema.rb")
        runner_path = File.join(dir, "runner.rb")
        File.write(schema_path, schema)
        File.write(runner_path, runner_source)
        database_url = isolated_database_url(dir)
        capture = @runner.new(
          env: process_env(database_url, schema_path, migrations),
          command: [ "bash", "-c", 'status=0; cleanup=0; bin/rails db:create && bin/rails runner "$SYRUS_ARTIFACT_RUNNER" || status=$?; DISABLE_DATABASE_ENVIRONMENT_CHECK=1 bin/rails db:drop || cleanup=$?; if [ "$cleanup" -ne 0 ]; then echo "SYRUS_ARTIFACT_CLEANUP_ERROR: disposable database drop failed" >&2; fi; [ "$status" -ne 0 ] && exit "$status"; exit "$cleanup"' ],
          mounts: ProcessRunner.mounts(@workspace.to_s, read_write: @workspace.to_s, read_only: dir),
          network: "grader", timeout: TIMEOUT, kind: "artifact", workflow: @workflow,
          display_command: "generate Rails migration artifacts"
        ).capture
        unless capture.result.success?
          detail = capture.result.timed_out? ? "timed out after #{TIMEOUT}s" : capture.stderr.to_s.lines.last(12).join.strip
          stage = capture.stderr.include?("SYRUS_ARTIFACT_CLEANUP_ERROR") ? "cleanup" : "migration execution"
          raise GenerationError, "#{stage} failed: #{detail.presence || "exit #{capture.result.exit_status}"}"
        end
        line = capture.stdout.lines.reverse.find { |candidate| candidate.start_with?(RESULT_PREFIX) }
        raise GenerationError, "migration introspection produced no result" unless line
        JSON.parse(line.delete_prefix(RESULT_PREFIX)).transform_keys { |key| "db/migrate/#{key}" }
      ensure
        FileUtils.rm_f(URI.parse(database_url).path) if database_url&.start_with?("sqlite3:")
      end
    rescue DisposableDatabaseUnavailable => e
      fallback(base, migrations, e.message)
    rescue GenerationError => e
      stage = e.message.start_with?("cleanup failed:") ? "cleanup" : "execution"
      migrations.index_with { |path| error_payload(path, stage, e.message) }
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
      adapter = configured_adapter
      return "sqlite3:#{File.join(dir, "artifact-#{SecureRandom.hex(12)}.sqlite3")}" if adapter.match?(/sqlite/i)

      template = ENV["SYRUS_RAILS_ARTIFACT_DATABASE_URL"].presence
      raise DisposableDatabaseUnavailable, "#{adapter} artifact execution requires SYRUS_RAILS_ARTIFACT_DATABASE_URL" unless template
      uri = URI.parse(template)
      raise GenerationError, "artifact database target must use the repository adapter" unless uri.scheme.to_s.include?(adapter.sub("ql", ""))
      raise GenerationError, "artifact database target must be local" unless LOCAL_HOSTS.include?(uri.host)
      uri.path = "/syrus_artifact_#{Digest::SHA256.hexdigest([ @workspace.realpath, Process.pid, SecureRandom.hex ].join(":"))[0, 24]}"
      uri.to_s
    rescue URI::InvalidURIError => e
      raise GenerationError, "invalid artifact database URL: #{e.message}"
    end

    def configured_adapter
      path = @workspace.join("config/database.yml")
      raw = path.read.gsub(/<%=.*?%>/m, "")
      config = YAML.safe_load(raw, aliases: true) || {}
      config.dig("development", "adapter") || config.dig("default", "adapter") || raise(GenerationError, "cannot determine database adapter")
    rescue Psych::Exception => e
      raise GenerationError, "cannot read database configuration: #{e.message}"
    end

    def process_env(url, schema_path, migrations)
      {
        "RAILS_ENV" => "development", "DATABASE_URL" => url,
        "SYRUS_ARTIFACT_SANDBOX" => "1", "SYRUS_ARTIFACT_SCHEMA" => schema_path,
        "SYRUS_ARTIFACT_MIGRATIONS" => JSON.generate(migrations.map { |path| @workspace.join(path).to_s }),
        "SYRUS_ARTIFACT_RUNNER" => File.join(File.dirname(schema_path), "runner.rb"),
        "CACHE_DATABASE_URL" => url, "QUEUE_DATABASE_URL" => url, "CABLE_DATABASE_URL" => url
      }
    end

    def fallback(base, migrations, reason)
      head = @workspace.join("db/schema.rb")
      base_content = @git.run("show", "#{base}:db/schema.rb", chdir: @workspace.to_s)
      raise GenerationError, "#{reason}; schema-dump fallback unavailable" unless head.file?
      before = SchemaParser.new(base_content).parse[:tables]
      after = SchemaParser.parse(head)[:tables]
      payload = catalog_payload(File.basename(migrations.last, ".rb"), before, after)
      payload[:status] = "cumulative_fallback"
      payload[:cumulative] = true
      payload[:message] = "Cumulative schema diff for #{migrations.length} migration(s); per-migration attribution unavailable: #{reason}"
      migrations.index_with { payload }
    rescue StandardError => e
      migrations.index_with { |path| error_payload(path, "fallback", "#{reason}; #{e.message}") }
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
        ActiveRecord::Base.establish_connection(ENV.fetch("DATABASE_URL"))
        connection = ActiveRecord::Base.connection
        load ENV.fetch("SYRUS_ARTIFACT_SCHEMA")
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
