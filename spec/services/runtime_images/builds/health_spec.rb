require "rails_helper"
require "support/synthetic_runtime_image_provider"

RSpec.describe RuntimeImages::Builds::Health do
  let(:provider) { SyntheticRuntimeImageProvider.new }
  let(:namespace) { RuntimeImageNamespace.create!(name: "acme/widgets", owner_kind: "k", owner_ref: "1", provider_key: provider.key) }
  let(:orchestrator) { RuntimeImages::Builds::Orchestrator.new }
  let(:config) { RuntimeImages::Builds::Config }

  after { RuntimeImages::Builds.builder = nil }

  def submit(revision: "f" * 40)
    source = RuntimeImages::Builds::SourceCapture.capture(kind: "git", ref: "git://repo", revision: revision)
    orchestrator.submit(namespace: namespace, source: source, recipe: {}, platform: "linux/amd64", requester_kind: "t", requester_ref: "1")
  end

  def statuses(now: Time.current) = described_class.new(now: now).checks.to_h { |check| [ check.name, check.status ] }

  it "is quiet and dark when nothing was ever requested" do
    expect(statuses.values.uniq).to eq([ :ok ])
    expect(described_class.new.snapshot).to include(builder_registered: false, oldest_queued_seconds: nil, stale_attempts: 0)
  end

  it "warns when requests are queued but no executor is registered" do
    submit
    expect(statuses["build executor"]).to eq(:warn)
  end

  it "warns when the oldest queued request has waited past the stuck threshold" do
    RuntimeImages::Builds.builder = double("builder")
    request = submit
    expect(statuses["build queue"]).to eq(:ok)
    expect(statuses(now: request.created_at + config.stuck_queue_after + 1.minute)["build queue"]).to eq(:warn)
  end

  it "fails when an active attempt is far past its lease, meaning recovery is not running" do
    RuntimeImages::Builds.builder = double("builder")
    submit
    _, attempt = orchestrator.claim_next

    expect(statuses(now: attempt.lease_expires_at + 1.minute)["stale build attempts"]).to eq(:ok)
    late = attempt.lease_expires_at + config.stale_lease_grace + 1.minute
    expect(statuses(now: late)["stale build attempts"]).to eq(:fail)

    orchestrator.reap_expired(now: late)
    expect(statuses(now: late)["stale build attempts"]).to eq(:ok)
  end

  it "flags an attempt past the runtime ceiling whose lease keeps being renewed" do
    RuntimeImages::Builds.builder = double("builder")
    submit
    _, attempt = orchestrator.claim_next
    late = attempt.started_at + config.max_attempt_runtime + config.stale_lease_grace + 1.minute
    orchestrator.heartbeat(attempt, now: late)

    expect(statuses(now: late)["stale build attempts"]).to eq(:fail)
  end

  it "warns on orphaned in-flight requests" do
    RuntimeImages::Builds.builder = double("builder")
    request = submit
    orchestrator.claim_next
    request.attempts.update_all(state: "failed")

    expect(statuses["orphaned build requests"]).to eq(:warn)
  end

  it "warns on a high failure ratio, denied destinations, and quota exhaustion" do
    RuntimeImages::Builds.builder = double("builder")
    6.times do |i|
      request = submit(revision: i.to_s * 40)
      _, attempt = orchestrator.claim(request.id)
      code = { 0 => "network_denied", 1 => "quota_exhausted" }.fetch(i, "build_failed")
      orchestrator.fail_attempt(attempt, code: code, detail: "m", retryable: false)
    end

    expect(statuses).to include("build failures" => :warn, "build network" => :warn, "build quota" => :warn)
    snapshot = described_class.new.snapshot
    expect(snapshot[:outcomes_24h]).to eq("failed" => 6)
    expect(snapshot[:error_codes_24h]).to include("network_denied" => 1, "quota_exhausted" => 1, "build_failed" => 4)
    expect(snapshot[:recent_failures].size).to eq(6)
  end

  it "reports in-flight work and limits without log text or hosts" do
    RuntimeImages::Builds.builder = double("builder")
    request = submit
    orchestrator.claim_next

    snapshot = described_class.new.snapshot

    expect(snapshot[:in_flight].first).to include(request_id: request.id, state: "building", attempt: 1)
    expect(snapshot[:limits]).to include(concurrency: config.max_concurrent_builds, max_attempts: config.max_attempts)
    expect(snapshot.to_json).not_to match(/address|"log"/)
  end

  it "is part of the Runtime Image Service health checks and snapshot" do
    expect(RuntimeImages::Health.new.checks.map(&:name)).to include("build queue", "stale build attempts")
    expect(RuntimeImages::Health.new.snapshot).to include(:builds)
  end

  describe Metrics::RuntimeImageSampler do
    before { allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new) }

    def gauge(name, tags = {}) = Syrus::Metrics.gauge(name).samples.find { |labels, _| labels.symbolize_keys == tags }&.last

    it "exports request states, queue age, and stale attempts" do
      RuntimeImages::Builds.builder = double("builder")
      request = submit
      submit(revision: "9" * 40)
      orchestrator.claim_next

      described_class.sample!
      described_class.refresh_gauges!

      expect(gauge(:syrus_runtime_image_build_requests, { state: "building" })).to eq(1)
      expect(gauge(:syrus_runtime_image_build_requests, { state: "queued" })).to eq(1)
      expect(gauge(:syrus_runtime_image_build_oldest_queued_seconds)).to be >= 0
      expect(gauge(:syrus_runtime_image_build_stale_attempts)).to eq(0)
      expect(request).to be_present
    end
  end
end
