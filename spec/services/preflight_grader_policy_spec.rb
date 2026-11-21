require "rails_helper"
require "tmpdir"
require "erb"
require "yaml"

RSpec.describe PreflightGraderPolicy do
  describe ".wave_size" do
    it "defaults, honors the env override, and clamps to the maximum" do
      expect(described_class.wave_size(env: {})).to eq(described_class::DEFAULT_WAVE_SIZE)
      expect(described_class.wave_size(env: { described_class::WAVE_SIZE_ENV => "3" })).to eq(3)
      expect(described_class.wave_size(env: { described_class::WAVE_SIZE_ENV => "9999" })).to eq(described_class::MAX_WAVE_SIZE)
      expect(described_class.wave_size(env: { described_class::WAVE_SIZE_ENV => "0" })).to eq(described_class::DEFAULT_WAVE_SIZE)
      expect(described_class.wave_size(env: { described_class::WAVE_SIZE_ENV => "junk" })).to eq(described_class::DEFAULT_WAVE_SIZE)
    end
  end

  it "slices work into waves no larger than the size" do
    waves = described_class.waves((1..130).to_a, size: 6)

    expect(waves.map(&:size).max).to eq(6)
    expect(waves.flatten).to eq((1..130).to_a)
  end

  describe "database isolation" do
    let(:step_a) { instance_double(Step, id: 11) }
    let(:step_b) { instance_double(Step, id: 12) }

    it "gives concurrent graders disjoint namespaces and database paths" do
      env_a = described_class.database_env(described_class.database_namespace(step_a))
      env_b = described_class.database_env(described_class.database_namespace(step_b))

      expect(env_a["TEST_ENV_NUMBER"]).not_to eq(env_b["TEST_ENV_NUMBER"])
      expect(env_a[described_class::NAMESPACE_ENV]).not_to eq(env_b[described_class::NAMESPACE_ENV])
    end

    # parallel_tests overwrites TEST_ENV_NUMBER for each worker process, so two
    # parallel RSpec shards in one checkout both opened storage/test.sqlite3 and
    # failed every example with SQLite3::BusyException.
    it "keeps parallel workers of concurrent graders on disjoint database files" do
      paths = [ step_a, step_b ].flat_map do |step|
        env = described_class.database_env(described_class.database_namespace(step))
        [ "", "2", "3" ].map do |worker|
          config = render_test_database_config(env.merge("TEST_ENV_NUMBER" => worker))
          [ config.dig("primary", "database"), config.dig("search", "database") ]
        end
      end.flatten

      expect(paths.uniq.size).to eq(paths.size)
      expect(paths).to include("storage/testpf11-2.sqlite3", "storage/test_searchpf12.sqlite3")
    end

    it "keeps a single-process grader on its namespace" do
      env = described_class.database_env(described_class.database_namespace(step_a))

      expect(render_test_database_config(env).dig("primary", "database")).to eq("storage/testpf11.sqlite3")
    end

    it "leaves ordinary test runs on the default database files" do
      expect(render_test_database_config({}).dig("primary", "database")).to eq("storage/test.sqlite3")
      expect(render_test_database_config("TEST_ENV_NUMBER" => "3").dig("search", "database")).to eq("storage/test_search3.sqlite3")
    end

    def render_test_database_config(env)
      original = ENV.to_h
      [ "TEST_ENV_NUMBER", described_class::NAMESPACE_ENV, "SEARCH_DATABASE_PATH" ].each { |key| ENV.delete(key) }
      env.each { |key, value| ENV[key] = value }
      YAML.safe_load(ERB.new(File.read(Rails.root.join("config/database.yml"))).result, aliases: true).fetch("test")
    ensure
      ENV.replace(original)
    end

    it "removes only the files of its own namespace" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "storage"))
        mine = %w[testpf11.sqlite3 testpf11.sqlite3-wal test_searchpf11.sqlite3 testpf11-2.sqlite3 test_searchpf11-3.sqlite3].map { |f| File.join(root, "storage", f) }
        theirs = %w[testpf12.sqlite3 test.sqlite3 testpf111.sqlite3].map { |f| File.join(root, "storage", f) }
        (mine + theirs).each { |f| File.write(f, "x") }

        removed = described_class.cleanup_database!(root, "pf11")

        expect(removed).to match_array(mine)
        expect(mine.none? { |f| File.exist?(f) }).to be(true)
        expect(theirs.all? { |f| File.exist?(f) }).to be(true)
      end
    end
  end
end
