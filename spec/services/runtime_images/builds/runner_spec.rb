require "rails_helper"
require "support/synthetic_runtime_image_provider"

RSpec.describe RuntimeImages::Builds::Runner do
  let(:provider) { SyntheticRuntimeImageProvider.new }
  let(:namespace) { RuntimeImageNamespace.create!(name: "acme/widgets", owner_kind: "k", owner_ref: "1", provider_key: provider.key) }
  let(:service) { RuntimeImages::Service.new(provider: provider) }
  let(:orchestrator) { RuntimeImages::Builds::Orchestrator.new }
  let(:builder) { double("builder") }
  let(:source) { RuntimeImages::Builds::SourceCapture.capture(kind: "git", ref: "git://repo", revision: "c" * 40) }
  let(:request) do
    orchestrator.submit(namespace: namespace, source: source, recipe: { "a" => 1 }, platform: "linux/amd64",
                        requester_kind: "test", requester_ref: "1")
  end

  before { RuntimeImages::Builds.builder = builder }
  after { RuntimeImages::Builds.builder = nil }

  def run
    claimed_request, attempt = orchestrator.claim_next
    described_class.new(orchestrator: orchestrator, service: service).call(claimed_request, attempt)
    [ claimed_request.reload, attempt.reload ]
  end

  def output(**attrs) = RuntimeImages::Builds::Output.new(payload: "image-bytes", source_digest: source.digest, provenance: { "builder" => "t" }, **attrs)

  it "builds, publishes, verifies, and records a successful result" do
    request
    allow(builder).to receive(:build).and_return(output)

    claimed, attempt = run

    expect(claimed).to be_succeeded
    expect(attempt.state).to eq("succeeded")
    image = claimed.result.runtime_image
    expect(image).to be_available
    expect(image.provenance["build_request_id"]).to eq(claimed.id)
    expect(image.source_digest).to eq(source.digest)
  end

  it "fails non-retryably when the builder consumed a different source" do
    request
    allow(builder).to receive(:build).and_return(output.tap { |o| o.source_digest = "sha256:#{"9" * 64}" })

    claimed, = run

    expect(claimed).to be_failed
    expect(claimed.result.error_code).to eq("source_mismatch")
  end

  it "fails when the builder does not attest the source it consumed" do
    request
    allow(builder).to receive(:build).and_return(output.tap { |o| o.source_digest = nil })

    claimed, = run

    expect(claimed).to be_failed
    expect(claimed.result.error_code).to eq("source_unattested")
  end

  it "retries when verification finds the image absent" do
    request
    allow(builder).to receive(:build).and_return(output)
    allow_any_instance_of(SyntheticRuntimeImageProvider).to receive(:inspect_image).and_wrap_original do |m, req|
      m.call(req).with(present: false)
    end

    claimed, attempt = run

    expect(claimed).to be_queued
    expect(attempt.error_code).to eq("verification_failed")
  end

  it "treats an unreachable registry as a retryable failure with its own code" do
    request
    allow(builder).to receive(:build).and_raise(RuntimeImages::ProviderError, "registry down")

    claimed, attempt = run

    expect(claimed).to be_queued
    expect(attempt).to have_attributes(error_code: "registry_unavailable", retryable: true)
    expect(claimed.next_attempt_at).to be > Time.current + 1.minute
  end

  it "treats a registry that rejects a publish for quota as quota exhaustion, retried on the slow schedule" do
    request
    allow(builder).to receive(:build).and_return(output)
    allow_any_instance_of(RuntimeImages::Builds::ScopedPublisher).to receive(:publish).and_raise(RuntimeImages::ProviderError, "429 Too Many Requests: quota exceeded")

    claimed, attempt = run

    expect(claimed).to be_queued
    expect(attempt).to have_attributes(error_code: "quota_exhausted", retryable: true)
    expect(claimed.next_attempt_at).to be > Time.current + 5.minutes
  end

  it "treats a full disk as quota exhaustion" do
    request
    allow(builder).to receive(:build).and_raise(Errno::ENOSPC)

    _, attempt = run

    expect(attempt).to have_attributes(error_code: "quota_exhausted", retryable: true)
  end

  it "fails terminally, naming no hosts, when a build fails after the egress proxy refused destinations" do
    request
    allow(builder).to receive(:build) do |control:, **|
      control.evidence.instance_variable_set(:@network, { "denials" => [ { "host" => "evil.example", "port" => 443, "reason" => "not_allowlisted", "count" => 2 } ] })
      raise RuntimeImages::Builds::BuildFailed.new("build exited with status 1", code: "build_failed")
    end

    claimed, attempt = run

    expect(claimed).to be_failed
    expect(attempt).to have_attributes(error_code: "network_denied", retryable: false)
    expect(claimed.result.message).to include("2 refused network request", "not_allowlisted")
    expect(claimed.result.message).not_to include("evil.example")
  end

  it "keeps a non-generic failure code even when destinations were refused" do
    request
    allow(builder).to receive(:build) do |control:, **|
      control.evidence.instance_variable_set(:@network, { "denials" => [ { "host" => "x", "reason" => "not_allowlisted", "count" => 1 } ] })
      raise RuntimeImages::Builds::BuildFailed.new("too slow", code: "build_timeout")
    end

    claimed, = run

    expect(claimed.result.error_code).to eq("build_timeout")
  end

  it "records unexpected errors as terminal failures" do
    request
    allow(builder).to receive(:build).and_raise(ArgumentError, "bug")

    claimed, = run

    expect(claimed).to be_failed
    expect(claimed.result.error_code).to eq("unexpected_error")
  end

  it "honors a cancel requested before the build starts" do
    request
    claimed_request, attempt = orchestrator.claim_next
    orchestrator.cancel(claimed_request)
    expect(builder).not_to receive(:build)

    described_class.new(orchestrator: orchestrator, service: service).call(claimed_request, attempt)

    expect(claimed_request.reload).to be_canceled
  end

  it "honors a cancel raised by the builder mid-build and publishes nothing" do
    request
    allow(builder).to receive(:build) { |control:, **| orchestrator.cancel(request); control.raise_if_canceled! }

    claimed, = run

    expect(claimed).to be_canceled
    expect(provider.calls.map(&:first)).not_to include(:publish)
  end

  describe "evidence and scoped publication" do
    let(:layer) { "sha256:#{"1" * 64}" }
    let(:manifest) { JSON.generate("schemaVersion" => 2, "layers" => [ { "digest" => layer } ]) }

    it "binds a succeeded attempt to its source, policy, builder, layers, and result" do
      request
      allow(builder).to receive(:build) do |control:, **|
        control.evidence.builder_version = "buildah 9"
        control.evidence.policy_digest = "sha256:#{"p" * 64}"
        control.evidence.record_bases([ "alpine:3" ], [])
        control.evidence.log.write("hello\npassword=hunter2\n")
        output(payload: { manifest: manifest, blobs: {} })
      end

      claimed, attempt = run

      evidence = attempt.evidence
      expect(evidence).to have_attributes(outcome: "succeeded", source_digest: source.digest, builder_version: "buildah 9",
                                          layer_digests: [ layer ], runtime_image: claimed.result.runtime_image)
      expect(evidence.image_digest).to eq(claimed.result.runtime_image.digest)
      expect(evidence.log).to eq("hello\npassword=[REDACTED]\n")
      expect(claimed.result.details.dig("evidence", "layer_digests")).to eq([ layer ])
      expect(claimed.result.details.to_json).not_to include("hello")
      provenance = claimed.result.runtime_image.provenance
      expect(provenance).to include("builder_version" => "buildah 9", "layer_digests" => [ layer ], "build_request_id" => claimed.id)
      expect(provenance.to_json).not_to include("hunter2")
      expect(RuntimeImageAuditEvent.where(event_type: "build.evidence").count).to eq(1)
    end

    it "records evidence for a failed attempt, including the log up to the failure" do
      request
      allow(builder).to receive(:build) do |control:, **|
        control.evidence.log.write("compiling\n")
        raise RuntimeImages::Builds::BuildFailed.new("exit 2", code: "build_failed")
      end

      claimed, attempt = run

      expect(claimed).to be_failed
      expect(attempt.evidence).to have_attributes(outcome: "failed", error_code: "build_failed", log: "compiling\n", runtime_image: nil)
      expect(claimed.result.details.dig("evidence", "outcome")).to eq("failed")
    end

    it "records evidence for a retried attempt without writing a result" do
      request
      allow(builder).to receive(:build).and_raise(RuntimeImages::ProviderError, "registry down")

      claimed, attempt = run

      expect(claimed).to be_queued
      expect(attempt.evidence).to have_attributes(outcome: "failed", error_code: "registry_unavailable")
      expect(claimed.result).to be_nil
    end

    it "records evidence for a canceled attempt" do
      request
      allow(builder).to receive(:build) { |control:, **| orchestrator.cancel(request); control.raise_if_canceled! }

      _, attempt = run

      expect(attempt.evidence).to have_attributes(outcome: "canceled")
    end

    it "does not let an evidence failure change the build outcome" do
      request
      allow(builder).to receive(:build).and_return(output)
      allow(RuntimeImageBuildEvidence).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, "boom")

      claimed, = run

      expect(claimed).to be_succeeded
    end

    it "refuses to publish outside the request's namespace" do
      request
      allow(builder).to receive(:build).and_return(output)
      other = RuntimeImageNamespace.create!(name: "acme/other", owner_kind: "k", owner_ref: "2", provider_key: provider.key)
      allow(service).to receive(:publish).and_wrap_original { |m, **attrs| m.call(**attrs, namespace: other) }

      claimed, = run

      expect(claimed).to be_failed
      expect(claimed.result).to have_attributes(outcome: "failed", error_code: "unexpected_error", runtime_image: nil)
    end
  end
end
