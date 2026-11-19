require "rails_helper"
require "open3"
require "tmpdir"

RSpec.describe "bin/rspec-shard-files" do
  let(:script) { Rails.root.join("bin/rspec-shard-files").to_s }

  def shard(index, total, runtime_log: "/nonexistent/runtime.log")
    stdout, stderr, status = Open3.capture3({ "RSPEC_RUNTIME_LOG" => runtime_log, "SYRUS_PLUGIN_PATH" => nil }, script, index.to_s, total.to_s)
    expect(status).to be_success, stderr
    stdout.lines.map(&:chomp)
  end

  it "splits exactly the default suite into disjoint shards" do
    shards = (1..3).map { |index| shard(index, 3) }
    all = shards.flatten

    expected = Dir.chdir(Rails.root) do
      (Dir["spec/**/*_spec.rb"] + Dir["plugins/**/spec/**/*_spec.rb"]).uniq.sort
    end
    expect(all.sort).to eq(expected)
    expect(all.uniq.size).to eq(all.size)
    expect(shards).to all(be_present)
    expect(all).to include("spec/scripts/rspec_shard_files_spec.rb")
  end

  it "is deterministic" do
    expect(shard(2, 4)).to eq(shard(2, 4))
  end

  it "balances by recorded runtimes when a runtime log exists" do
    Dir.mktmpdir do |dir|
      log = File.join(dir, "runtime.log")
      # One very slow file must sit alone in its shard.
      File.write(log, "spec/scripts/rspec_shard_files_spec.rb:100000.0\n")

      slow_shard = (1..2).map { |index| shard(index, 2, runtime_log: log) }
        .find { |files| files.include?("spec/scripts/rspec_shard_files_spec.rb") }

      expect(slow_shard).to eq([ "spec/scripts/rspec_shard_files_spec.rb" ])
    end
  end

  it "rejects an out-of-range shard" do
    _stdout, stderr, status = Open3.capture3(script, "5", "4")

    expect(status.exitstatus).to eq(2)
    expect(stderr).to include("usage: bin/rspec-shard-files INDEX TOTAL")
  end

  describe "CI wiring" do
    let(:jobs) { YAML.load_file(Rails.root.join(".github/workflows/ci.yml")).fetch("jobs") }

    it "runs one rspec shard per matrix entry, with the shard count matching the matrix" do
      rspec = jobs.fetch("rspec")
      shards = rspec.dig("strategy", "matrix", "shard")
      run = rspec.fetch("steps").map { |step| step["run"].to_s }.find { |command| command.include?("bin/rspec-ci") }

      expect(shards).to eq((1..shards.size).to_a)
      expect(run).to include("bin/rspec-shard-files ${{ matrix.shard }} #{shards.size}")
    end

    # Regression: the relocation acceptance boots Rails, and was added to a
    # Node-only job where bin/rails cannot run.
    it "sets up Ruby in every job that boots Rails for the relocation acceptance" do
      relocation_jobs = jobs.select do |_name, job|
        job.fetch("steps").any? { |step| step["run"].to_s.include?("bin/test-plugin-relocation") }
      end

      expect(relocation_jobs).not_to be_empty
      relocation_jobs.each do |name, job|
        expect(job.fetch("steps").map { |step| step["uses"].to_s }).to include(start_with("ruby/setup-ruby")), name
      end
    end
  end
end
