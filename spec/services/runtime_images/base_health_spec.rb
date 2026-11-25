require "rails_helper"
require "support/coworker_base_release_helpers"

RSpec.describe RuntimeImages::Health, "coworker base" do
  include CoworkerBaseReleaseHelpers

  before { allow(BaseRebuildDiscoveryJob).to receive(:perform_later) }

  def base_check = described_class.new.checks.find { |check| check.name == "coworker base" }

  it "is ok when no base was ever published" do
    expect(base_check.status).to eq(:ok)
  end

  it "warns while only candidates exist" do
    candidate
    expect(base_check).to have_attributes(status: :warn)
    expect(base_check.detail).to include("awaiting promotion")
  end

  it "is ok with an active base and flags waiting candidates" do
    active_base
    candidate
    expect(base_check).to have_attributes(status: :ok)
    expect(base_check.detail).to include("1 candidate")
  end

  it "fails when the promoted base was revoked and nothing replaced it" do
    base_releases.revoke!(active_base, reason: "bad", severity: "severe", actor: "t")
    expect(base_check.status).to eq(:fail)
    expect(base_check.detail).to include("blocked")
  end

  it "warns when environments need a rebuild" do
    old = active_base
    publish_environment(old)
    active_base
    base_releases.revoke!(old.reload, reason: "bad", actor: "t")
    expect(base_check.status).to eq(:warn)
  end

  it "exposes the promotion state in the diagnostics snapshot" do
    active_base
    snapshot = described_class.new.snapshot
    amd = snapshot[:coworker_base][:platforms].find { |p| p[:platform] == "linux/amd64" }
    expect(amd).to include(state: :ready)
    expect(snapshot[:coworker_base]).to include(:candidates, :revoked, :needing_rebuild)
  end
end
