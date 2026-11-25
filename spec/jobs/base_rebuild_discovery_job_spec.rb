require "rails_helper"
require "support/coworker_base_release_helpers"

RSpec.describe BaseRebuildDiscoveryJob do
  include CoworkerBaseReleaseHelpers

  before { allow(BaseRebuildDiscoveryJob).to receive(:perform_later) }

  it "audits environments needing a rebuild after a base change" do
    release = active_base
    publish_environment(release)
    base_releases.revoke!(release, reason: "bad", actor: "t")

    expect(described_class.new.perform).to eq(1)
    event = RuntimeImageAuditEvent.where(event_type: "base_release.rebuild_needed").last
    expect(event).to have_attributes(outcome: "detected")
    expect(event.details).to include("total" => 1, "blocked" => 1)
  end

  it "stays quiet when nothing needs a rebuild" do
    active_base
    expect(described_class.new.perform).to eq(0)
    expect(RuntimeImageAuditEvent.where(event_type: "base_release.rebuild_needed")).to be_empty
  end

  it "repairs a release whose image was revoked behind its back" do
    release = active_base
    base_service.revoke(release.runtime_image, reason: "conformance failed")
    allow(RuntimeImages::BaseReleases).to receive(:new).and_return(base_releases)
    described_class.new.perform
    expect(release.reload).to be_revoked
  end

  it "is enqueued by lifecycle changes" do
    allow(BaseRebuildDiscoveryJob).to receive(:perform_later).and_call_original
    expect { active_base }.to have_enqueued_job(described_class)
  end

  it "runs on a consumed queue" do
    expect(described_class.new.queue_name).to eq("cleanup")
  end
end
