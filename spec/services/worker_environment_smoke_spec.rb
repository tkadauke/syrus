require "rails_helper"

RSpec.describe WorkerEnvironmentSmoke do
  # A check double: answers a fixed result without touching the host.
  def fake_check(name, result)
    Class.new do
      define_method(:name) { name }
      define_method(:call) { |shell:, env:| result.respond_to?(:call) ? result.call(env) : result }
    end.new
  end

  def passed(essential: false) = { "status" => "passed", "detail" => "ok", "essential" => essential }
  def failed(reason, essential: false) = { "status" => "failed", "reason" => reason, "essential" => essential }

  after { described_class.reset! }

  describe "#call" do
    it "passes when every check passes" do
      report = described_class.new(checks: [ fake_check("git", passed(essential: true)), fake_check("npm", passed) ]).call

      expect(report).to include("version" => 1, "status" => "passed", "failed" => [])
      expect(report.fetch("checks").keys).to contain_exactly("git", "npm")
      expect(report.fetch("checks").fetch("git")).to include("status" => "passed", "duration_ms" => be_a(Integer))
    end

    it "is degraded, not failed, when only non-essential checks fail" do
      report = described_class.new(checks: [
        fake_check("git", passed(essential: true)),
        fake_check("mysql_client", failed("no mysql_config found"))
      ]).call

      expect(report).to include("status" => "degraded", "failed" => [ "mysql_client" ])
    end

    it "fails when an essential check fails" do
      report = described_class.new(checks: [
        fake_check("workflow_data_root", failed("flock failed", essential: true)),
        fake_check("mysql_client", failed("no mysql_config found"))
      ]).call

      expect(report).to include("status" => "failed", "failed" => %w[mysql_client workflow_data_root])
    end

    it "records a check that raises as failed instead of taking the report down" do
      exploding = fake_check("node", ->(_env) { raise Errno::EIO, "disk on fire" })

      report = described_class.new(checks: [ exploding ]).call

      expect(report.fetch("failed")).to eq([ "node" ])
      expect(report.dig("checks", "node", "reason")).to include("Errno::EIO")
    end

    # Checks must see exactly what a prepare command sees, so a variable the
    # worker has but prepare does not forward cannot make a check pass.
    it "hands checks only the forwarded prepare environment" do
      seen = nil
      check = fake_check("probe", ->(env) { seen = env; passed })

      described_class.new(checks: [ check ], env: { "PATH" => "/opt/tools/bin", "HOME" => "/home/syrus", "RAILS_ENV" => "production" }).call

      expect(seen).to include("PATH" => "/opt/tools/bin", "HOME" => "/home/syrus")
      expect(seen).not_to have_key("RAILS_ENV")
    end
  end

  describe ".failed_checks / .blocking_failures" do
    let(:report) { { "failed" => %w[mysql_client gh], "checks" => { "mysql_client" => { "reason" => "no mysql_config" } } } }

    it "intersects a report's failures with what a step needs" do
      expect(described_class.blocking_failures(report, %w[git mysql_client])).to eq([ "mysql_client" ])
      expect(described_class.blocking_failures(report, %w[git node])).to eq([])
    end

    it "treats a missing or malformed report as unknown, never as broken" do
      expect(described_class.failed_checks(nil)).to eq([])
      expect(described_class.failed_checks("garbage")).to eq([])
      expect(described_class.blocking_failures(nil, %w[git mysql_client])).to eq([])
    end

    it "names the reason for each failure" do
      expect(described_class.failure_reasons(report, [ "mysql_client" ])).to eq("mysql_client" => "no mysql_config")
    end
  end

  describe ".publishable?" do
    it "publishes only from worker processes outside the test suite" do
      allow(Rails.env).to receive(:test?).and_return(false)

      expect(described_class.publishable?(env: { "SYRUS_ROLE" => "worker" })).to be(true)
      expect(described_class.publishable?(env: { "SYRUS_ROLE" => "web" })).to be(false)
      expect(described_class.publishable?(env: { "SYRUS_ROLE" => "worker", "SYRUS_WORKER_ENVIRONMENT_SMOKE" => "0" })).to be(false)
    end

    it "never publishes from the test suite" do
      expect(described_class.publishable?(env: { "SYRUS_ROLE" => "worker" })).to be(false)
    end
  end

  describe ".refresh_if_stale!" do
    it "computes once and reuses the report until the refresh interval passes" do
      runs = 0
      allow(described_class).to receive(:new) do
        runs += 1
        instance_double(described_class, call: { "observed_at" => Time.now.utc.iso8601, "failed" => [], "run" => runs })
      end

      first = described_class.refresh_if_stale!
      again = described_class.refresh_if_stale!
      later = described_class.refresh_if_stale!(now: Time.now + described_class::REFRESH_INTERVAL_SECONDS + 1)

      expect(first).to equal(again)
      expect(later.fetch("run")).to eq(2)
      expect(described_class.current).to equal(later)
    end
  end

  describe "WorkerCapabilities publication" do
    before do
      allow(WorkerCapabilities).to receive(:detected_defaults).and_return(capabilities: { "os" => [ "linux" ] }, diagnostics: {})
    end

    it "adds the report to the capability diagnostics of a worker process" do
      allow(described_class).to receive(:publishable?).and_return(true)
      allow(described_class).to receive(:current).and_return("status" => "degraded", "failed" => [ "mysql_client" ])

      diagnostics = WorkerCapabilities.current.fetch(:diagnostics)

      expect(diagnostics.fetch("environment_smoke")).to include("failed" => [ "mysql_client" ])
    end

    it "publishes nothing from a process that is not a worker" do
      expect(WorkerCapabilities.current.fetch(:diagnostics)).not_to have_key("environment_smoke")
    end
  end
end
