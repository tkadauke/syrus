require "rails_helper"
require "support/coworker_base_release_helpers"

RSpec.describe RuntimeImages::BaseCompatibility do
  include CoworkerBaseReleaseHelpers

  before { allow(BaseRebuildDiscoveryJob).to receive(:perform_later) }

  subject(:compat) { described_class.new }

  it "reports nothing while environments sit on a supported base, even a superseded one" do
    old = active_base
    publish_environment(old)
    active_base
    expect(old.reload).to be_retired
    expect(compat.environments_needing_rebuild).to be_empty
  end

  it "finds environments on a revoked base and names the replacement" do
    old = active_base
    env = publish_environment(old)
    unrelated = publish_environment(candidate)
    replacement = active_base
    base_releases.revoke!(old.reload, reason: "bad", actor: "t")

    findings = compat.environments_needing_rebuild
    expect(findings.map(&:image)).to eq([ env ])
    expect(findings.first.reasons).to eq([ "base_revoked" ])
    expect(findings.first.replacement).to eq(replacement)
    expect(findings.map(&:image)).not_to include(unrelated)
  end

  it "marks environments blocked when the base was revoked and nothing replaces it" do
    release = active_base
    publish_environment(release)
    base_releases.revoke!(release, reason: "root escape", severity: "severe", actor: "t")
    finding = compat.environments_needing_rebuild.first
    expect(finding.reasons).to eq([ "base_revoked_severe" ])
    expect(finding.replacement).to be_nil
    expect(compat.summary).to include(total: 1, blocked: 1, by_reason: { "base_revoked_severe" => 1 })
  end

  it "finds environments once a support window has ended" do
    old = active_base
    publish_environment(old)
    active_base
    base_releases.set_support_deadline!(old.reload, until_time: 1.hour.from_now, actor: "t")
    expect(compat.environments_needing_rebuild).to be_empty
    expect(described_class.new(now: 2.hours.from_now).environments_needing_rebuild.first.reasons).to eq([ "support_ended" ])
  end

  it "finds environments on a base whose ABI this Syrus no longer launches" do
    release = active_base
    publish_environment(release)
    CoworkerBaseRelease.where(id: release.id).update_all(runtime_abi: 99, compat_min: 99, compat_max: 99)
    expect(compat.environments_needing_rebuild.first.reasons).to eq([ "abi_unsupported" ])
  end

  it "ignores deleted or revoked environment images and the bases themselves" do
    release = active_base
    env = publish_environment(release)
    base_service.revoke(env, reason: "x")
    base_releases.revoke!(release, reason: "bad", actor: "t")
    expect(compat.environments_needing_rebuild).to be_empty
  end
end
