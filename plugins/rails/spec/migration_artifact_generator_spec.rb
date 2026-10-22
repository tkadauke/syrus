require "rails_helper"
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
    expect(runner).to receive(:new) do |options|
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

  it "emits an explicit generation error when migration execution fails" do
    path = "db/migrate/20261022000001_create_widgets.rb"
    @workspace.join(path).write("class CreateWidgets; end")
    @workspace.join("db/schema.rb").write(base_schema.sub("users", "widgets"))
    stub_git([ path ])
    failed = double(result: double(success?: false, timed_out?: false, exit_status: 1), stdout: "", stderr: "boom")
    runner = double("runner class", new: double(capture: failed))

    result = generator(runner: runner).generate(path)
    expect(result[:status]).to eq("error")
    expect(result[:stage]).to eq("execution")
    expect(result[:message]).to include("migration execution failed")
  end

  it "uses a cumulative schema diff when disposable database creation is unavailable" do
    path = "db/migrate/20261022000001_create_widgets.rb"
    @workspace.join(path).write("class CreateWidgets; end")
    @workspace.join("db/schema.rb").write(base_schema.sub("users", "widgets"))
    @workspace.join("config/database.yml").write("default:\n  adapter: postgresql\n")
    stub_git([ path ])

    with_env("SYRUS_RAILS_ARTIFACT_DATABASE_URL", nil) do
      result = generator.generate(path)
      expect(result[:status]).to eq("cumulative_fallback")
      expect(result[:cumulative]).to be(true)
    end
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
