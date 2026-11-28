require "rails_helper"
require "support/coworker_base_release_helpers"

# NY47 (A): a severe coworker base revocation withdraws what was built on that
# base. BaseReleases#revoke! promised that severity became a termination
# signal, but nothing consumed it: running turns on the base kept running, and
# environments built FROM it kept launching (F159).
RSpec.describe "Severe coworker base revocation" do
  include CoworkerBaseReleaseHelpers

  let(:owner) { Factories.user }
  let(:coworker) do
    Coworkers::Coworker.create!(owner_user: owner, name: "Builder", handle: "cascade-builder",
                                workspace_repo: "https://github.com/acme/widgets.git")
  end
  let(:release) { active_base }
  let(:environment_image) { publish_environment(release) }
  let(:environment) { Coworkers::Environment.create!(coworker: coworker, state: "active") }
  let!(:revision) do
    Coworkers::EnvironmentRevision.create!(environment: environment, number: 1, state: "active",
                                           source_digest: "sha256:#{'d' * 64}", runtime_abi: 3,
                                           compat_min: 2, compat_max: 4, base_release: release,
                                           runtime_image: environment_image).tap do |created|
      environment.update!(active_revision: created, active_runtime_image: environment_image)
    end
  end

  before do
    allow(Syrus::Host::AgentRuntime).to receive(:terminate_chat_processes).and_return(1)
    # The environment image lives in a namespace with no registered provider
    # here; withdraw it as the registry would.
    allow(Syrus::Host::RuntimeImages).to receive(:revoke) { |runtime_image, reason:, **| runtime_image.mark_revoked!(reason:) }
  end

  it "revokes environments built on the base and stops their turns" do
    base_releases.revoke!(release, reason: "CVE in node", severity: "severe", actor: "user:1")

    expect(revision.reload).to be_revoked
    expect(environment.reload.active_revision_id).to be_nil
    expect(environment_image.reload).not_to be_pullable
    expect(Syrus::Host::AgentRuntime).to have_received(:terminate_chat_processes)
      .with(hash_including(runtime_image_digest: environment_image.digest))
  end

  it "leaves environments alone for a standard revocation" do
    base_releases.revoke!(release, reason: "superseded", severity: "standard", actor: "user:1")

    expect(revision.reload).not_to be_revoked
    expect(Syrus::Host::AgentRuntime).not_to have_received(:terminate_chat_processes)
  end
end
