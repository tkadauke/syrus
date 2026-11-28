require "rails_helper"
require "support/coworker_base_release_helpers"

RSpec.describe RuntimeImages::BaseReleases do
  include CoworkerBaseReleaseHelpers

  before { allow(BaseRebuildDiscoveryJob).to receive(:perform_later) }

  def audit(type) = RuntimeImageAuditEvent.where(event_type: type)

  describe "#register" do
    it "records a signed published base as a candidate with the signed ABI facts, once" do
      image = publish_base
      release = base_releases.register(image)
      expect(release).to be_candidate
      expect(release).to have_attributes(runtime_abi: RuntimeImages::RuntimeAbi.version, platform: "linux/amd64",
                                         compat_min: RuntimeImages::RuntimeAbi.compatibility["min"])
      expect(base_releases.register(image)).to eq(release)
      expect(CoworkerBaseRelease.count).to eq(1)
    end

    it "refuses a base without a valid signed attestation" do
      expect(base_releases.register(publish_base(signed: false))).to be_nil
      expect(CoworkerBaseRelease.count).to eq(0)
      expect(audit("base_release.register").last.outcome).to eq("failed")
    end
  end

  describe "#promote!" do
    it "activates a candidate, makes it the launch image, and audits it" do
      release = candidate
      expect(base_releases.launch_state.code).to eq("no_active_base")

      base_releases.promote!(release, actor: "user:1")

      expect(release.reload).to be_active
      expect(release.promoted_by).to eq("user:1")
      expect(base_releases.current_image).to eq(release.runtime_image)
      expect(base_releases.launch_state).to be_ready
      expect(audit("base_release.promote").last.details).to include("platform" => "linux/amd64")
      expect(BaseRebuildDiscoveryJob).to have_received(:perform_later)
    end

    it "retires the previous base, retaining it for the rollback window" do
      AppSetting.current.update!(runtime_environment_policy: { "base" => { "rollback_retention_days" => 14 } })
      first = active_base
      second = candidate
      base_releases.promote!(second, actor: "test")

      expect(first.reload).to be_retired
      expect(second.reload).to be_active
      expect(first.runtime_image.reload).to have_attributes(retention_state: "retained")
      expect(first.runtime_image.retain_until).to be_within(1.minute).of(14.days.from_now)
      expect(CoworkerBaseRelease.active.count).to eq(1)
    end

    # F138: activate! checked the release before taking the platform lock, so
    # a revocation landing in between was overwritten by status "active".
    it "refuses to activate a release revoked after the check, keeping it revoked" do
      release = candidate
      allow(base_service).to receive(:retain).and_wrap_original do |original, image, **args|
        if image == release.runtime_image
          # A concurrent revoke! commits here, between the check and the switch.
          release.class.where(id: release.id).update_all(status: "revoked", active_key: nil, revoked_at: Time.current, revoked_reason: "spec")
        end
        original.call(image, **args)
      end

      expect { base_releases.promote!(release, actor: "test") }.to raise_error(described_class::Refused) { |e| expect(e.codes).to include("not_a_candidate") }
      expect(release.reload).to be_revoked
      expect(CoworkerBaseRelease.active.count).to eq(0)
    end

    it "refuses cleanly when another promotion switched the active base after the check" do
      first = active_base
      winner = candidate
      loser = candidate
      allow(base_service).to receive(:retain).and_wrap_original do |original, image, **args|
        if image == loser.runtime_image && !winner.reload.active?
          # A concurrent promote! of another candidate commits here.
          RuntimeImages::BaseReleases.new(service: RuntimeImages::Service.new(provider: base_provider)).promote!(winner, actor: "other")
        end
        original.call(image, **args)
      end

      expect { base_releases.promote!(loser, actor: "test") }.to raise_error(described_class::Refused) { |e| expect(e.codes).to include("concurrent_change") }
      expect(winner.reload).to be_active
      expect(loser.reload).to be_candidate
      expect(first.reload).to be_retired
    end

    it "keeps one active base per platform independently" do
      amd = active_base
      arm = active_base(platform: "linux/arm64")
      expect([ amd.reload, arm.reload ]).to all(be_active)
    end

    it "refuses anything but a candidate, and an unlaunchable one" do
      active = active_base
      expect { base_releases.promote!(active, actor: "t") }.to raise_error(described_class::Refused) { |e| expect(e.codes).to eq([ "not_a_candidate" ]) }

      stale = candidate
      CoworkerBaseRelease.where(id: stale.id).update_all(runtime_abi: 99, compat_min: 99, compat_max: 99)
      stale.reload
      expect { base_releases.promote!(stale, actor: "t") }.to raise_error(described_class::Refused) { |e| expect(e.codes).to include("abi_unsupported", "abi_range_excludes_syrus") }
      expect(stale.reload).to be_candidate
    end

    it "refuses promotion outside the administrator-supported ABI window" do
      allow(RuntimeImages::RuntimeAbi).to receive(:compatibility).and_return("min" => 1, "max" => 2)
      AppSetting.current.update!(runtime_environment_policy: {
        "base" => { "supported_abi_min" => 2, "supported_abi_max" => 2 }
      })
      release = candidate

      expect { base_releases.promote!(release, actor: "test") }
        .to raise_error(described_class::Refused) { |error| expect(error.codes).to include("abi_unsupported") }
    end

    it "does not switch when the registry cannot retain the base being replaced" do
      first = active_base
      second = candidate
      allow(base_provider).to receive(:retain).and_raise(RuntimeImages::ProviderError, "registry down")
      expect { base_releases.promote!(second, actor: "t") }.to raise_error(RuntimeImages::ProviderError)
      expect(first.reload).to be_active
      expect(second.reload).to be_candidate
    end
  end

  describe "#rollback!" do
    it "re-activates the most recent retired base and retires the current one" do
      first = active_base
      second = active_base
      expect(first.reload).to be_retired

      base_releases.rollback!(actor: "user:2")

      expect(first.reload).to be_active
      expect(second.reload).to be_retired
      expect(base_releases.current_image).to eq(first.runtime_image)
      expect(audit("base_release.rollback").count).to eq(1)
    end

    it "never rolls back to a revoked, deleted, or missing base" do
      first = active_base
      active_base
      base_releases.revoke!(first.reload, reason: "bad", actor: "t")
      expect { base_releases.rollback!(actor: "t") }.to raise_error(described_class::Refused) { |e| expect(e.codes).to eq([ "no_rollback_target" ]) }
      expect { base_releases.rollback!(to: first, actor: "t") }.to raise_error(described_class::Refused) { |e| expect(e.codes).to eq([ "not_retired" ]) }
    end

    it "refuses an explicit target that belongs to another platform" do
      arm = active_base(platform: "linux/arm64")
      active_base(platform: "linux/arm64")
      active_base
      expect(arm.reload).to be_retired
      expect { base_releases.rollback!(platform: "linux/amd64", to: arm, actor: "t") }.to raise_error(described_class::Refused) { |e| expect(e.codes).to eq([ "platform_mismatch" ]) }
      expect(arm.reload).to be_retired
    end

    it "refuses a candidate as rollback target" do
      active_base
      expect { base_releases.rollback!(to: candidate, actor: "t") }.to raise_error(described_class::Refused) { |e| expect(e.codes).to eq([ "not_retired" ]) }
    end
  end

  describe "#revoke!" do
    it "blocks new launches, revokes the image at the registry, and audits the actor and severity" do
      release = active_base
      base_releases.revoke!(release, reason: "CVE in node", severity: "severe", actor: "user:3")

      expect(release.reload).to be_revoked
      expect(release).to have_attributes(revocation_severity: "severe", revoked_by: "user:3", active_key: nil)
      expect(release.runtime_image.reload).to be_revoked
      expect(base_provider.calls.map(&:first)).to include(:revoke)
      expect(base_releases.current_image).to be_nil
      state = base_releases.launch_state
      expect(state.code).to eq("base_revoked")
      expect(state.message).to include("CVE in node")
      expect(audit("base_release.revoke").last.details).to include("severity" => "severe", "was_active" => true)
    end

    it "requires a reason and a known severity, and refuses a second revocation" do
      release = active_base
      expect { base_releases.revoke!(release, reason: " ", actor: "t") }.to raise_error(described_class::Refused) { |e| expect(e.codes).to eq([ "reason_required" ]) }
      expect { base_releases.revoke!(release, reason: "x", severity: "mild", actor: "t") }.to raise_error(ArgumentError)
      base_releases.revoke!(release, reason: "x", actor: "t")
      expect { base_releases.revoke!(release.reload, reason: "x", actor: "t") }.to raise_error(described_class::Refused) { |e| expect(e.codes).to eq([ "already_revoked" ]) }
    end

    it "revokes a candidate or retired base without touching the active one" do
      active = active_base
      other = candidate
      base_releases.revoke!(other, reason: "bad build", actor: "t")
      expect(active.reload).to be_active
      expect(base_releases.current_image).to eq(active.runtime_image)
    end

    it "leaves the release untouched when the registry call fails, so it can be retried" do
      release = active_base
      allow(base_provider).to receive(:revoke).and_raise(RuntimeImages::ProviderError, "registry down")
      expect { base_releases.revoke!(release, reason: "x", actor: "t") }.to raise_error(RuntimeImages::ProviderError)
      expect(release.reload).to be_active
    end
  end

  describe "#sync_with_images!" do
    it "revokes a release whose image was revoked outside the lifecycle" do
      release = active_base
      base_service.revoke(release.runtime_image, reason: "conformance failed")
      expect(base_releases.sync_with_images!).to eq([ release ])
      expect(release.reload).to be_revoked
      expect(release.revoked_reason).to eq("conformance failed")
      expect(base_releases.current_image).to be_nil
    end
  end

  describe "#set_support_deadline!" do
    it "sets and clears the support window and audits it" do
      release = active_base
      deadline = 2.days.from_now
      base_releases.set_support_deadline!(release, until_time: deadline, actor: "user:1")
      expect(release.reload.supported_until).to be_within(1.second).of(deadline)
      expect(release.supported?).to be(true)
      expect(release.supported?(3.days.from_now)).to be(false)
      base_releases.set_support_deadline!(release, until_time: nil, actor: "user:1")
      expect(release.reload.supported_until).to be_nil
      expect(audit("base_release.support").count).to eq(2)
    end

    it "refuses a revoked base" do
      release = active_base
      base_releases.revoke!(release, reason: "x", actor: "t")
      expect { base_releases.set_support_deadline!(release.reload, until_time: 1.day.from_now, actor: "t") }.to raise_error(described_class::Refused)
    end
  end

  describe "database guarantee" do
    it "rejects two active releases on one platform" do
      first = active_base
      other = candidate
      expect { other.update_columns(status: "active", active_key: first.platform) }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end
end
