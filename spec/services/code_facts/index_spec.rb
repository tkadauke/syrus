require "rails_helper"

RSpec.describe CodeFacts::Index do
  around do |example|
    Dir.mktmpdir("syrus-code-facts") do |dir|
      @repo_path = Pathname.new(dir)
      example.run
    end
  end

  let(:repo_path) { @repo_path }
  let(:now) { Time.zone.parse("2026-09-28 12:00:00 UTC") }

  before do
    git("init")
    git("config", "user.email", "agent@example.com")
    git("config", "user.name", "Syrus Agent")
  end

  it "indexes file facts at the requested commit and excludes generated and vendor files from rollups" do
    write(".syrus.yml", <<~YAML)
      generated:
        - command: bin/generate
          sources: app/models/order.rb
          generates:
            - app/generated/**
    YAML
    write("app/models/order.rb", <<~RUBY)
      class Order
        def total(discount)
          discount ? 10 : 12
        end
      end
    RUBY
    write("app/generated/client.rb", "class GeneratedClient\nend\n")
    write("cli/.syrus.yml", <<~YAML)
      generated:
        - command: go generate ./...
          generates:
            - gen/**
    YAML
    write("cli/gen/client.go", "package gen\n")
    write("vendor/bundle/ruby/gem.rb", "module Vendored\nend\n")
    write("README.md", "# Widgets\n")
    git("add", ".")
    commit("initial", at: now - 40.days)
    initial_sha = rev_parse("HEAD")

    write("app/models/order.rb", <<~RUBY)
      class Order
        def total(discount)
          if discount
            10
          else
            12
          end
        end
      end
    RUBY
    git("add", "app/models/order.rb")
    commit("increase order branching", at: now - 2.days)

    write("README.md", "# Widgets\n\nHuman notes.\n")
    git("add", "README.md")
    commit("touch docs", at: now - 1.day)
    head_sha = rev_parse("HEAD")

    result = described_class.for_workspace(workspace_path: repo_path, sha: head_sha, churn_windows: [ 7, 30 ], now: now)

    order = file(result, "app/models/order.rb")
    expect(order.language).to eq("Ruby")
    expect(order.type).to eq("code")
    expect(order.line_count).to eq(9)
    expect(order.excluded).to be(false)
    expect(order.churn).to eq(7 => 1, 30 => 1)
    expect(order.last_modified_days_ago).to eq(2)
    expect(order.complexity).to include("source" => "heuristic")
    expect(order.complexity["score"]).to be > 1

    generated = file(result, "app/generated/client.rb")
    expect(generated.excluded).to be(true)
    expect(generated.exclusion_reasons).to include("generated")

    vendored = file(result, "vendor/bundle/ruby/gem.rb")
    expect(vendored.excluded).to be(true)
    expect(vendored.exclusion_reasons).to include("vendor")

    nested_generated = file(result, "cli/gen/client.go")
    expect(nested_generated.excluded).to be(true)
    expect(nested_generated.exclusion_reasons).to include("generated")

    expect(result.rollup["file_count"]).to eq(4)
    expect(result.rollup["excluded_file_count"]).to eq(3)
    expect(result.rollup["line_count"]).to eq(21)
    expect(result.rollup["languages"]).to include("Ruby" => 1, "Markdown" => 1, "YAML" => 2)
    expect(result.rollup["churn"]).to eq(7 => 2, 30 => 2)

    initial_result = described_class.for_workspace(workspace_path: repo_path, sha: initial_sha, churn_windows: [ 7 ], now: now)
    expect(file(initial_result, "app/models/order.rb").line_count).to eq(5)
  end

  it "uses fallback complexity for unsupported file types" do
    write("README.md", "# Plain text\n")
    git("add", ".")
    commit("docs", at: now)

    result = described_class.for_workspace(workspace_path: repo_path, now: now)

    readme = file(result, "README.md")
    expect(readme.type).to eq("documentation")
    expect(readme.complexity).to eq("score" => nil, "source" => "unsupported")
    expect(result.rollup.dig("complexity", "average")).to be_nil
  end

  it "batches git facts instead of shelling out once per file" do
    write(".syrus.yml", "prepare: []\n")
    write("app/models/order.rb", "class Order\nend\n")
    write("app/models/customer.rb", "class Customer\nend\n")
    write("app/models/invoice.rb", "class Invoice\nend\n")
    git("add", ".")
    commit("code", at: now)
    runner = CountingGitRunner.new(repo_path)

    described_class.for_workspace(workspace_path: repo_path, now: now, churn_windows: [ 30 ], git: runner)

    expect(runner.commands.any? { |command| command.first == "show" }).to be(false)
    expect(runner.commands.any? { |command| command.first(2) == %w[log -1] }).to be(false)
    expect(runner.commands.count { |command| command.first == "log" }).to eq(2)
    expect(runner.commands.count { |command| command.first == "grep" }).to eq(3)
  end

  def file(result, path)
    result.files.find { |fact| fact.path == path } || raise("missing #{path}")
  end

  def write(path, contents)
    full_path = repo_path.join(path)
    FileUtils.mkdir_p(full_path.dirname)
    full_path.write(contents)
  end

  def commit(message, at:)
    git(
      "commit", "-m", message,
      env: {
        "GIT_AUTHOR_DATE" => at.utc.iso8601,
        "GIT_COMMITTER_DATE" => at.utc.iso8601
      }
    )
  end

  def rev_parse(ref)
    git("rev-parse", ref).strip
  end

  def git(*args, env: {})
    output = +""
    Bundler.with_unbundled_env do
      IO.popen(env, [ "git", *args ], chdir: repo_path.to_s, err: [ :child, :out ]) do |io|
        output = io.read
      end
    end
    raise "git #{args.join(' ')} failed:\n#{output}" unless $?.success?

    output
  end

  class CountingGitRunner
    attr_reader :commands

    def initialize(repo_path)
      @repo_path = repo_path
      @delegate = GitRunner.new
      @commands = []
    end

    def run(*args, chdir: nil, **options)
      commands << args.map(&:to_s)
      @delegate.run(*args, chdir: chdir || @repo_path.to_s, **options)
    end
  end
end
