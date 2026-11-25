require "rails_helper"
require "support/coworker_base_release_helpers"

RSpec.describe RuntimeImages::BaseRevocation do
  include CoworkerBaseReleaseHelpers

  before { allow(BaseRebuildDiscoveryJob).to receive(:perform_later) }

  it "is nil for a base that is not revoked or not a base at all" do
    release = active_base
    expect(described_class.for_digest(release.digest)).to be_nil
    expect(described_class.for_digest("sha256:#{"0" * 64}")).to be_nil
    expect(described_class.terminate?(release.digest)).to be(false)
  end

  it "asks running turns to terminate only for a severe revocation" do
    standard = active_base
    severe = candidate
    base_releases.revoke!(standard, reason: "cosmetic", actor: "t")
    base_releases.revoke!(severe, reason: "root escape", severity: "severe", actor: "t")

    expect(described_class.for_digest(standard.digest)).to have_attributes(severity: "standard", terminate?: false)
    signal = described_class.for_digest(severe.digest)
    expect(signal).to have_attributes(severity: "severe", terminate?: true, reason: "root escape")
    expect(described_class.terminate?(severe.digest)).to be(true)
    expect(described_class.terminating.map(&:digest)).to eq([ severe.digest ])
  end

  it "answers by the pinned digest regardless of which base is active now" do
    old = active_base
    base_releases.revoke!(old, reason: "root escape", severity: "severe", actor: "t")
    active_base
    expect(described_class.terminate?(old.digest)).to be(true)
  end

  it "lists only revocations since a cursor" do
    release = active_base
    base_releases.revoke!(release, reason: "x", severity: "severe", actor: "t")
    expect(described_class.terminating(since: 1.minute.from_now)).to be_empty
    expect(described_class.terminating(since: 1.minute.ago).size).to eq(1)
  end
end
