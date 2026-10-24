require "rails_helper"
require "open3"
require "tmpdir"

RSpec.describe SyrusRails::MigrationArtifactGenerator do
  let(:workflow) { double("workflow") }
  let(:git) { double("git") }
  let(:base_ref) { "origin/main" }
  let(:base_schema) do
    <<~RUBY
      ActiveRecord::Schema[8.1].define do
        create_table "users" do |t|
          t.string "email"
        end
      end
    RUBY
  end

  before do
    @workspace = Pathname.new(Dir.mktmpdir("migration-artifacts"))
    @workspace.join("config").mkpath
    @workspace.join("db/migrate").mkpath
    @workspace.join("config/database.yml").write("default:\n  adapter: sqlite3\n")
    allow(WorkflowWorkspace).to receive(:new).with(workflow).and_return(double("workspace", base_ref: base_ref))
  end

  after { FileUtils.remove_entry(@workspace) if @workspace&.exist? }

  def generator(runner: ProcessRunner)
    described_class.new(workspace: @workspace, workflow: workflow, git: git, runner: runner)
  end

  def stub_git(migrations)
    allow(git).to receive(:run).with("merge-base", "HEAD", base_ref, chdir: @workspace.to_s).and_return("base-sha\n")
    allow(git).to receive(:run).with("diff", "--name-only", "--diff-filter=A", "base-sha", "--", "db/migrate/*.rb", chdir: @workspace.to_s).and_return(migrations.join("\n"))
    allow(git).to receive(:run).with("show", "base-sha:db/schema.rb", chdir: @workspace.to_s).and_return(base_schema)
  end

  def with_env(key, value)
    previous = ENV[key]
    value.nil? ? ENV.delete(key) : ENV[key] = value
    yield
  ensure
    previous.nil? ? ENV.delete(key) : ENV[key] = previous
  end

  it "returns the correctly attributed result after applying multiple migrations in order" do
    paths = %w[db/migrate/20261022000001_create_users.rb db/migrate/20261022000002_add_account.rb]
    paths.each { |path| @workspace.join(path).write("class Placeholder; end") }
    stub_git(paths)
    output = paths.to_h { |path| [ File.basename(path), { migration_name: File.basename(path, ".rb"), status: "success", before: { tables: [] }, after: { tables: [] } } ] }
    capture = double(result: double(success?: true), stdout: "noise\n#{described_class::RESULT_PREFIX}#{JSON.generate(output)}\n", stderr: "")
    process = double(capture: capture)
    runner = double("runner class")
    expect(runner).to receive(:new).twice do |options|
      expect(JSON.parse(options[:env].fetch("SYRUS_ARTIFACT_MIGRATIONS")).map { |path| File.basename(path) }).to eq(paths.map { |path| File.basename(path) })
      process
    end

    result = generator(runner: runner).generate(paths.last)
    expect(result[:migration_name] || result["migration_name"]).to eq("20261022000002_add_account")
  end

  it "uses unique disposable SQLite database names for parallel generators" do
    one = generator.send(:isolated_database_url, @workspace.to_s)
    two = generator.send(:isolated_database_url, @workspace.to_s)
    expect(one).not_to eq(two)
    expect(one).to start_with("sqlite3:")
  end

  it "rejects a non-local server database target" do
    @workspace.join("config/database.yml").write("default:\n  adapter: postgresql\n")
    with_env("SYRUS_RAILS_ARTIFACT_DATABASE_URL", "postgresql://db.example.com/template") do
      expect { generator.send(:isolated_database_url, @workspace.to_s) }.to raise_error(described_class::GenerationError, /must be local/)
    end
  end

  it "redirects every configured database, including nonstandard secondaries, to distinct sandboxes" do
    @workspace.join("config/database.yml").write(<<~YAML)
      development:
        primary:
          adapter: sqlite3
          database: storage/development.sqlite3
        analytics:
          adapter: sqlite3
          database: storage/analytics.sqlite3
    YAML
    urls = generator.send(:isolated_database_urls, @workspace.to_s)
    env = generator.send(:process_env, urls, "/tmp/schema.rb", :ruby, [])
    expect(env.fetch("PRIMARY_DATABASE_URL")).not_to eq(env.fetch("ANALYTICS_DATABASE_URL"))
    expect(JSON.parse(env.fetch("SYRUS_ARTIFACT_DATABASES"))).to contain_exactly(
      URI.parse(env.fetch("PRIMARY_DATABASE_URL")).path.delete_prefix("/"),
      URI.parse(env.fetch("ANALYTICS_DATABASE_URL")).path.delete_prefix("/")
    )
    expect(generator.send(:execution_command).last).to include("db:schema:load:primary")
  end

  it "emits an explicit generation error when migration execution fails" do
    path = "db/migrate/20261022000001_create_widgets.rb"
    @workspace.join(path).write("class CreateWidgets; end")
    @workspace.join("db/schema.rb").write(base_schema.sub("users", "widgets"))
    stub_git([ path ])
    failed = double(result: double(success?: false, timed_out?: false, exit_status: 1), stdout: "", stderr: "boom")
    cleaned = double(result: double(success?: true), stdout: "", stderr: "")
    runner = double("runner class")
    expect(runner).to receive(:new).with(hash_including(command: generator.send(:execution_command))).ordered.and_return(double(capture: failed))
    expect(runner).to receive(:new).with(hash_including(command: generator.send(:cleanup_command))).ordered.and_return(double(capture: cleaned))

    result = generator(runner: runner).generate(path)
    expect(result[:status]).to eq("error")
    expect(result[:stage]).to eq("execution")
    expect(result[:message]).to include("migration execution failed")
  end

  it "reports cleanup failures separately from successful migration execution" do
    path = "db/migrate/20261022000001_create_widgets.rb"
    @workspace.join(path).write("class CreateWidgets; end")
    stub_git([ path ])
    output = { File.basename(path) => { migration_name: "CreateWidgets", status: "success" } }
    executed = double(result: double(success?: true), stdout: "#{described_class::RESULT_PREFIX}#{JSON.generate(output)}\n", stderr: "")
    cleanup = double(result: double(success?: false, timed_out?: false, exit_status: 1), stderr: "permission denied")
    runner = double("runner class")
    allow(runner).to receive(:new).with(hash_including(command: generator.send(:execution_command))).and_return(double(capture: executed))
    allow(runner).to receive(:new).with(hash_including(command: generator.send(:cleanup_command))).and_return(double(capture: cleanup))

    result = generator(runner: runner).generate(path)
    expect(result).to include(status: "error", stage: "cleanup")
    expect(result[:message]).to include("permission denied")
  end

  it "uses a cumulative schema diff when disposable database creation is unavailable" do
    path = "db/migrate/20261022000001_create_widgets.rb"
    @workspace.join(path).write("class CreateWidgets; end")
    @workspace.join("db/schema.rb").write(base_schema.sub("users", "widgets"))
    @workspace.join("config/database.yml").write("default:\n  adapter: postgresql\n")
    stub_git([ path ])

    with_env("SYRUS_RAILS_ARTIFACT_DATABASE_URL", nil) do
      result = generator.generate(path)
      expect(result[:status]).to eq("cumulative_fallback"), result.inspect
      expect(result[:cumulative]).to be(true)
    end
  end

  it "compares normalized structure.sql dumps for a structure-only fallback" do
    path = "db/migrate/20261022000001_create_widgets.rb"
    @workspace.join(path).write("class CreateWidgets; end")
    @workspace.join("db/structure.sql").write("-- head\nCREATE TABLE widgets (id bigint);\n")
    @workspace.join("config/database.yml").write("default:\n  adapter: postgresql\n")
    allow(git).to receive(:run).with("merge-base", "HEAD", base_ref, chdir: @workspace.to_s).and_return("base-sha\n")
    allow(git).to receive(:run).with("diff", "--name-only", "--diff-filter=A", "base-sha", "--", "db/migrate/*.rb", chdir: @workspace.to_s).and_return(path)
    allow(git).to receive(:run).with("show", "base-sha:db/schema.rb", chdir: @workspace.to_s).and_raise(GitRunner::GitError.new([ "show" ], 128, "missing"))
    allow(git).to receive(:run).with("show", "base-sha:db/structure.sql", chdir: @workspace.to_s).and_return("-- base\nCREATE TABLE accounts (id bigint);\n")

    with_env("SYRUS_RAILS_ARTIFACT_DATABASE_URL", nil) do
      result = generator.generate(path)
      expect(result[:status]).to eq("cumulative_fallback"), result.inspect
      expect(result.dig(:before, :structure)).to eq([ "CREATE TABLE accounts (id bigint)" ])
      expect(result.dig(:after, :structure)).to eq([ "CREATE TABLE widgets (id bigint)" ])
    end
  end

  it "loads a base structure.sql through the adapter schema task when a sandbox is available" do
    path = "db/migrate/20261022000001_create_widgets.rb"
    @workspace.join(path).write("class CreateWidgets; end")
    allow(git).to receive(:run).with("merge-base", "HEAD", base_ref, chdir: @workspace.to_s).and_return("base-sha\n")
    allow(git).to receive(:run).with("diff", "--name-only", "--diff-filter=A", "base-sha", "--", "db/migrate/*.rb", chdir: @workspace.to_s).and_return(path)
    allow(git).to receive(:run).with("show", "base-sha:db/schema.rb", chdir: @workspace.to_s).and_raise(GitRunner::GitError.new([ "show" ], 128, "missing"))
    allow(git).to receive(:run).with("show", "base-sha:db/structure.sql", chdir: @workspace.to_s).and_return("CREATE TABLE accounts (id integer);\n")
    output = { File.basename(path) => { migration_name: "CreateWidgets", status: "success", before: { tables: [] }, after: { tables: [] } } }
    capture = double(result: double(success?: true), stdout: "#{described_class::RESULT_PREFIX}#{JSON.generate(output)}\n", stderr: "")
    runner = double("runner class")
    expect(runner).to receive(:new).with(hash_including(command: generator(runner: runner).send(:execution_command))) do |options|
      expect(options[:env]).to include("SCHEMA_FORMAT" => "sql")
      expect(File.basename(options[:env].fetch("SCHEMA"))).to eq("structure.sql")
      expect(options[:command].last).to include("db:schema:load")
      double(capture: capture)
    end
    expect(runner).to receive(:new).with(hash_including(command: generator(runner: runner).send(:cleanup_command))).and_return(double(capture: double(result: double(success?: true))))

    expect(generator(runner: runner).generate(path)).to include("status" => "success")
  end

  it "executes the guarded create-table shape and introspects references, scalars, timestamps, and indexes" do
    schema = @workspace.join("base_schema.rb")
    migration = @workspace.join("db/migrate/20261022080636_create_workflow_artifact_values.rb")
    runner = @workspace.join("artifact_runner.rb")
    database = @workspace.join("artifact.sqlite3")
    schema.write("ActiveRecord::Schema[8.1].define {}\n")
    migration.write(<<~RUBY)
      class CreateWorkflowArtifactValues < ActiveRecord::Migration[8.1]
        def up
          return if table_exists?(:workflow_artifact_values)
          create_table :workflow_artifact_values do |t|
            t.references :workflow, null: false, index: true
            t.string :name, null: false
            t.text :value
            t.timestamps
          end
          add_index :workflow_artifact_values, [:workflow_id, :name], unique: true
        end
      end
    RUBY
    runner.write(generator.send(:runner_source))
    url = "sqlite3:#{database}"
    bootstrap = <<~RUBY
      module Rails; def self.env = "development"; end
      ActiveRecord::Base.configurations = { "development" => { "primary" => ENV.fetch("DATABASE_URL"), "analytics" => ENV.fetch("ANALYTICS_DATABASE_URL") } }
      ActiveRecord::Base.establish_connection(ENV.fetch("DATABASE_URL"))
      load ENV.fetch("SYRUS_ARTIFACT_SCHEMA")
      load ENV.fetch("SYRUS_ARTIFACT_RUNNER")
    RUBY
    stdout, stderr, status = Open3.capture3(
      {
        "DATABASE_URL" => url, "PRIMARY_DATABASE_URL" => url, "ANALYTICS_DATABASE_URL" => url,
        "SYRUS_ARTIFACT_SANDBOX" => "1", "SYRUS_ARTIFACT_SCHEMA" => schema.to_s,
        "SYRUS_ARTIFACT_RUNNER" => runner.to_s, "SYRUS_ARTIFACT_MIGRATIONS" => JSON.generate([ migration.to_s ]),
        "SYRUS_ARTIFACT_DATABASES" => JSON.generate([ database.to_s.delete_prefix("/") ])
      }, RbConfig.ruby, "-ractive_record", "-e", bootstrap
    )
    expect(status).to be_success, stderr
    payload = JSON.parse(stdout.lines.find { |line| line.start_with?(described_class::RESULT_PREFIX) }.delete_prefix(described_class::RESULT_PREFIX))
    table = payload.dig(migration.basename.to_s, "after", "tables", 0)
    expect(table.fetch("columns").map { |column| column.fetch("name") }).to include("workflow_id", "name", "value", "created_at", "updated_at")
    expect(table.fetch("indexes")).to include(hash_including("columns" => [ "workflow_id" ]), hash_including("columns" => [ "workflow_id", "name" ], "unique" => true))
  end

  it "runs database cleanup when migration execution fails" do
    bin = @workspace.join("bin")
    bin.mkpath
    database = @workspace.join("disposable.sqlite3")
    rails = bin.join("rails")
    rails.write(<<~SH)
      #!/bin/sh
      case "$*" in
        "db:create db:schema:load") touch "$ARTIFACT_TEST_DATABASE" ;;
        "runner "*) exit 23 ;;
        "db:drop") rm -f "$ARTIFACT_TEST_DATABASE" ;;
      esac
    SH
    rails.chmod(0o755)
    env = { "ARTIFACT_TEST_DATABASE" => database.to_s, "SYRUS_ARTIFACT_RUNNER" => "failure.rb" }
    _stdout, _stderr, status = Open3.capture3(env, *generator.send(:execution_command), chdir: @workspace.to_s)
    Open3.capture3(env, *generator.send(:cleanup_command), chdir: @workspace.to_s)
    expect(status.exitstatus).to eq(23)
    expect(database).not_to exist
  end

  it "marks data-only results explicitly in the child protocol" do
    expect(generator.send(:runner_source)).to include('status: names.empty? ? "no_schema_changes" : "success"')
  end

  it "captures references, indexes, timestamps, and check constraints from Active Record catalog APIs" do
    source = generator.send(:runner_source)
    expect(source).to include("connection.columns", "connection.indexes", "connection.foreign_keys", "connection.check_constraints")
  end

  it "reduces catalog snapshots to structurally changed tables" do
    unchanged = { name: "accounts", columns: [ { name: "id", type: "integer" } ] }
    before = [ unchanged, { name: "widgets", columns: [] } ]
    after = [ unchanged, { name: "widgets", columns: [ { name: "account_id", type: "bigint" } ] } ]
    payload = generator.send(:catalog_payload, "AddAccount", before, after)
    expect(payload.dig(:before, :tables).map { |table| table[:name] }).to eq([ "widgets" ])
    expect(payload.dig(:after, :tables).map { |table| table[:name] }).to eq([ "widgets" ])
  end
end
