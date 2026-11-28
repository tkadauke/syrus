require "rails_helper"
require "support/coworker_base_release_helpers"

RSpec.describe Coworkers::TurnEnvironmentSelection do
  include CoworkerBaseReleaseHelpers

  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user:) }
  let(:chat) { ChatSession.create!(user:, repository:) }
  let(:message) { chat.messages.create!(role: "user", content: { "text" => "hello" }) }
  let(:coworker) do
    Coworkers::Coworker.create!(owner_user: user, name: "Maya", handle: "turn-image-maya",
                                workspace_repo: repository.remote_url)
  end

  # NY48 (B): per-turn pinning refused every coworker turn while no base had
  # ever been promoted, which is how production stands, so a deploy would have
  # stopped every coworker chat (F160). Until a base is promoted, and while
  # custom environments are off, the turn runs as it did before pinning.
  describe "with no coworker base ever promoted" do
    def custom_environments(enabled)
      Feature.create!(slug: "coworker_custom_environments", category: "Labs", name: "x",
                      enabled: enabled, experimental: true)
    end

    it "runs the turn unpinned while custom environments are off" do
      custom_environments(false)
      resolver = described_class.new(coworker:, user_message: message)

      expect(resolver.resolve).to be_nil
      expect(Coworkers::TurnEnvironmentBinding.where(user_message_id: message.id)).to be_empty
    end

    it "still refuses the turn while custom environments are on" do
      custom_environments(true)

      expect { described_class.new(coworker:, user_message: message).resolve }
        .to raise_error(described_class::Unavailable, /no coworker base has been promoted/)
    end

    it "still refuses the turn once a promoted base was revoked" do
      custom_environments(false)
      base_releases.revoke!(active_base, reason: "bad", actor: "test")

      expect { described_class.new(coworker:, user_message: message).resolve }
        .to raise_error(described_class::Unavailable, /revoked/)
    end
  end

  it "uses and records the standard base while the feature gate is disabled" do
    release = active_base
    Feature.create!(slug: "coworker_custom_environments", category: "Labs", name: "x",
                    enabled: false, experimental: true)
    resolver = described_class.new(coworker:, user_message: message)

    selection = resolver.resolve
    binding = resolver.persist!(chat_session: chat)

    expect(selection).to have_attributes(
      kind: "standard", feature_gate_enabled: false, base_release_id: release.id,
      runtime_image_id: release.runtime_image_id, image_digest: release.digest,
      base_digest: release.digest, runtime_abi: release.runtime_abi, revocation_state: "available"
    )
    expect(binding).to have_attributes(
      chat_session: chat, user_message: message, coworker:, selection_kind: "standard",
      feature_gate_enabled: false, image_digest: release.digest, runtime_abi: release.runtime_abi
    )
  end

  it "reuses the durable digest when the gate and active base change later" do
    original = active_base(payload: "original")
    Feature.create!(slug: "coworker_custom_environments", category: "Labs", name: "x",
                    enabled: false, experimental: true)
    resolver = described_class.new(coworker:, user_message: message)
    resolver.resolve
    resolver.persist!(chat_session: chat)

    Feature.find_by!(slug: "coworker_custom_environments").update!(enabled: true)
    base_releases.promote!(candidate(payload: "replacement"), actor: "test")

    expect(described_class.resolve(coworker:, user_message: message)).to have_attributes(
      image_digest: original.digest, feature_gate_enabled: false
    )
  end

  it "fails closed when an active custom revision is incompatible with the live ABI" do
    release = active_base
    Feature.create!(slug: "coworker_custom_environments", category: "Labs", name: "x",
                    enabled: true, experimental: true)
    environment = Coworkers::Environment.create!(coworker:, state: "active")
    image = publish_environment(release)
    revision = Coworkers::EnvironmentRevision.create!(
      environment:, number: 1, state: "active", source_digest: "sha256:#{'f' * 64}",
      runtime_image: image, base_release: release, runtime_abi: 99, compat_min: 99, compat_max: 99
    )
    active = Coworkers::EnvironmentActiveSelection::Selection.new(
      activation_id: 7, revision_id: revision.id, runtime_image_id: image.id,
      image_digest: image.digest, runtime_image: image
    )
    allow(coworker).to receive(:environment).and_return(environment)
    allow(environment).to receive(:active_activation).and_return(instance_double(Coworkers::EnvironmentActivation))
    allow(Coworkers::EnvironmentActiveSelection).to receive(:resolve).with(environment).and_return(active)
    allow(Syrus::Host::RuntimeImages).to receive(:current_launch_contract?).and_return(true)

    expect { described_class.resolve(coworker:, user_message: message) }
      .to raise_error(described_class::Unavailable, /incompatible with runtime ABI/)
  end

  it "fails closed before launch when the selected provider contract is stale" do
    release = active_base
    Feature.create!(slug: "coworker_custom_environments", category: "Labs", name: "x",
                    enabled: true, experimental: true)
    environment = Coworkers::Environment.create!(coworker:, state: "active")
    image = publish_environment(release)
    revision = Coworkers::EnvironmentRevision.create!(environment:, number: 1, state: "active",
      source_digest: "sha256:#{'f' * 64}", runtime_image: image, base_release: release,
      runtime_abi: release.runtime_abi, compat_min: release.compat_min, compat_max: release.compat_max)
    active = Coworkers::EnvironmentActiveSelection::Selection.new(activation_id: 7,
      revision_id: revision.id, runtime_image_id: image.id, image_digest: image.digest, runtime_image: image)
    allow(coworker).to receive(:environment).and_return(environment)
    allow(environment).to receive(:active_activation).and_return(instance_double(Coworkers::EnvironmentActivation))
    allow(Coworkers::EnvironmentActiveSelection).to receive(:resolve).with(environment).and_return(active)
    allow(Syrus::Host::RuntimeImages).to receive(:current_launch_contract?)
      .with(image, provider: chat.effective_chat_provider).and_return(false)

    expect { described_class.resolve(coworker:, user_message: message) }
      .to raise_error(described_class::Unavailable, /provider contract is incompatible/)
  end
end
