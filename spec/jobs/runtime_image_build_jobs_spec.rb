require "rails_helper"
require "support/synthetic_runtime_image_provider"

RSpec.describe "runtime image build jobs" do
  let(:provider) { SyntheticRuntimeImageProvider.new }
  let(:namespace) { RuntimeImageNamespace.create!(name: "acme/widgets", owner_kind: "k", owner_ref: "1", provider_key: provider.key) }
  let(:orchestrator) { RuntimeImages::Builds::Orchestrator.new }
  let(:source) { RuntimeImages::Builds::SourceCapture.capture(kind: "git", ref: "git://repo", revision: "d" * 40) }

  after { RuntimeImages::Builds.builder = nil }

  def submit = orchestrator.submit(namespace: namespace, source: source, recipe: {}, platform: "linux/amd64", requester_kind: "t", requester_ref: "1")

  it "declares consumed queues" do
    expect(RuntimeImageBuildJob.new.queue_name).to eq("runtime_image_builds")
    expect(RuntimeImageBuildDispatchJob.new.queue_name).to eq("control_plane")
  end

  describe RuntimeImageBuildDispatchJob do
    include ActiveJob::TestHelper

    it "stays dark without a registered builder" do
      submit
      expect { described_class.perform_now }.not_to have_enqueued_job(RuntimeImageBuildJob)
      expect(RuntimeImageBuildRequest.queued.count).to eq(1)
    end

    it "claims startable requests and enqueues one build job per attempt" do
      RuntimeImages::Builds.builder = double("builder")
      request = submit

      expect { described_class.perform_now }.to have_enqueued_job(RuntimeImageBuildJob).with(request.id, kind_of(Integer))
      expect(request.reload).to be_building
    end

    it "reaps expired leases" do
      RuntimeImages::Builds.builder = double("builder")
      request = submit
      _, attempt = orchestrator.claim_next
      attempt.update!(lease_expires_at: 1.minute.ago)

      described_class.perform_now

      expect(attempt.reload.state).to eq("failed")
      expect(request.reload).to be_queued
    end
  end

  describe RuntimeImageBuildJob do
    it "runs the claimed attempt through the registered builder" do
      builder = double("builder")
      allow(builder).to receive(:build).and_return(RuntimeImages::Builds::Output.new(payload: "x", source_digest: source.digest, provenance: {}))
      RuntimeImages::Builds.builder = builder
      allow_any_instance_of(RuntimeImages::Service).to receive(:provider_for).and_return(provider)
      request, attempt = (submit && orchestrator.claim_next)

      described_class.perform_now(request.id, attempt.id)

      expect(request.reload).to be_succeeded
    end

    it "is a no-op for an attempt that is no longer active" do
      RuntimeImages::Builds.builder = double("builder")
      request, attempt = (submit && orchestrator.claim_next)
      orchestrator.fail_attempt(attempt, code: "x", detail: "m", retryable: false)

      expect { described_class.perform_now(request.id, attempt.id) }.not_to change { RuntimeImageBuildResult.count }
    end
  end
end
