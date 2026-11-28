require "rails_helper"

RSpec.describe RuntimeImageVerificationAttempt do
  let(:namespace) { RuntimeImageNamespace.create!(name: "verification-retention", owner_kind: "test", owner_ref: "1", provider_key: "test") }
  let(:image) do
    RuntimeImage.create!(runtime_image_namespace: namespace, digest: "sha256:#{"a" * 64}",
                         source_kind: "test", source_ref: "source")
  end

  def attempt(number:, state:)
    described_class.create!(runtime_image: image, number: number, image_digest: image.digest,
                            policy_digest: "sha256:#{"b" * 64}", state: state,
                            started_at: number.minutes.ago, finished_at: state == "running" ? nil : Time.current)
  end

  it "prunes only superseded terminal attempts and retains the latest attempt" do
    superseded = attempt(number: 1, state: "rejected")
    latest = attempt(number: 2, state: "accepted")
    running = attempt(number: 3, state: "running")

    expect(described_class.prunable).to contain_exactly(superseded)
    expect(described_class.prunable).not_to include(latest, running)
  end
end
