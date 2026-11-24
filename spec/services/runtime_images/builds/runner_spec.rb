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

  it "treats provider errors as retryable infrastructure failures" do
    request
    allow(builder).to receive(:build).and_raise(RuntimeImages::ProviderError, "registry down")

    claimed, attempt = run

    expect(claimed).to be_queued
    expect(attempt).to have_attributes(error_code: "infrastructure_error", retryable: true)
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
end
