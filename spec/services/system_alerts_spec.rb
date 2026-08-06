require "rails_helper"

RSpec.describe SystemAlerts do
  describe ".active_for" do
    it "returns no alerts for a healthy user" do
      user = Factories.user
      allow(DataRootDiskUsage).to receive(:current).and_return(nil)
      expect(described_class.active_for(user: user)).to be_empty
    end

    it "returns no alerts for an anonymous request (user: nil)" do
      expect(described_class.active_for(user: nil)).to eq([])
    end

    it "surfaces a github-token-blocked alert when the user is flagged" do
      user = Factories.user
      user.mark_gh_api_blocked!("Resource not accessible by personal access token")
      allow(DataRootDiskUsage).to receive(:current).and_return(nil)

      alerts = described_class.active_for(user: user)
      expect(alerts.size).to eq(1)
      alert = alerts.first

      expect(alert.severity).to eq(:alarm)
      expect(alert.title).to match(/GitHub API access/i)
      # Verbatim API response is wrapped in <code> for visual contrast
      # with the surrounding prose.
      expect(alert.message).to include("<code>Resource not accessible by personal access token</code>")
      expect(alert.action_steps.size).to be >= 2
      expect(alert.action_steps.join).to match(/scope|read/)
      expect(alert.cta).to eq(text: "Update token", path: "/credentials")
    end

    it "html-escapes the verbatim API reason before wrapping in <code> (untrusted content)" do
      user = Factories.user
      user.mark_gh_api_blocked!("oops <script>alert(1)</script>")
      allow(DataRootDiskUsage).to receive(:current).and_return(nil)
      alert = described_class.active_for(user: user).first
      expect(alert.message).to include("&lt;script&gt;alert(1)&lt;/script&gt;")
      expect(alert.message).not_to include("<script>")
    end

    it "alert id is stable per user — same user, same id, so banners can be deduplicated" do
      user = Factories.user
      user.mark_gh_api_blocked!("anything")
      allow(DataRootDiskUsage).to receive(:current).and_return(nil)
      first  = described_class.active_for(user: user).first
      second = described_class.active_for(user: user).first
      expect(first.id).to eq(second.id)
    end

    it "surfaces low Codex usage warnings" do
      user = Factories.user(
        codex_usage_status: "warning",
        codex_usage_snapshot: {
          "remaining_percent" => 12.4,
          "primary" => { "label" => "5h", "remaining_percent" => 12.4, "reset_at" => "2026-07-30T18:00:00Z" },
          "secondary" => { "label" => "weekly", "remaining_percent" => 88.2, "reset_at" => "2026-08-05T18:00:00Z" }
        }
      )
      allow(DataRootDiskUsage).to receive(:current).and_return(nil)

      travel_to Time.zone.parse("2026-08-03T13:00:00Z") do
        alert = described_class.active_for(user: user).first

        expect(alert.id).to eq("codex_usage:#{user.id}")
        expect(alert.dismissal_key).to include("2026-07-30T18:00:00Z")
        expect(alert.severity).to eq(:warn)
        expect(alert.title).to include("low")
        expect(alert.message).to include("5h 12% remaining")
        expect(alert.message).to include("weekly 88% remaining")
        expect(alert.message).to include("Usage resets in less than a minute.")
        expect(alert.message).not_to include("The next reset is around")
        expect(alert.cta).to eq(text: "Open agent settings", path: "/settings/agent")
        expect(alert.actions).to contain_exactly(
          include(text: "Recheck Codex", path: "/api/v1/app/credentials/recheck_provider_availability")
        )
        expect(alert.action_steps.join(" ")).not_to include("Override only")
      end
    end

    it "surfaces resume override on low Codex usage only when the pause threshold is crossed" do
      user = Factories.user(
        provider_availability_pause_thresholds: { "codex" => 20 },
        codex_usage_status: "warning",
        codex_usage_snapshot: {
          "remaining_percent" => 12.4,
          "primary" => { "label" => "5h", "remaining_percent" => 12.4, "reset_at" => "2026-07-30T18:00:00Z" }
        }
      )
      allow(DataRootDiskUsage).to receive(:current).and_return(nil)

      alert = described_class.active_for(user: user).first

      expect(alert.actions).to include(
        include(text: "Recheck Codex", path: "/api/v1/app/credentials/recheck_provider_availability"),
        include(text: "Resume Codex anyway", path: "/api/v1/app/credentials/override_provider_availability", destructive: false)
      )
      expect(alert.action_steps.join(" ")).to include("Override only")
    end

    it "renders the Codex reset timestamp as a relative duration" do
      user = Factories.user(
        codex_usage_status: "warning",
        codex_usage_snapshot: {
          "secondary" => { "label" => "weekly", "remaining_percent" => 19.0, "reset_at" => "2026-08-08T18:00:00Z" }
        }
      )
      allow(DataRootDiskUsage).to receive(:current).and_return(nil)

      travel_to Time.zone.parse("2026-08-06T13:00:00Z") do
        alert = described_class.active_for(user: user).first

        expect(alert.message).to include("Usage resets in 2 days, 5 hours.")
        expect(alert.message).not_to include("2026-08-08T18:00:00Z")
      end
    end

    it "keeps low Codex usage banner after later successful Codex evidence" do
      user = Factories.user
      ProviderAvailabilityEvidence.record_codex_probe!(
        user: user,
        status: "warning",
        snapshot: {
          "remaining_percent" => 18.0,
          "primary" => { "label" => "weekly", "remaining_percent" => 18.0, "used_percent" => 82.0 }
        },
        message: "Codex usage has 18% remaining.",
        observed_at: 2.minutes.ago
      )
      user.update!(
        codex_usage_status: "warning",
        codex_usage_observed_at: 2.minutes.ago,
        codex_usage_snapshot: {
          "remaining_percent" => 18.0,
          "primary" => { "label" => "weekly", "remaining_percent" => 18.0, "used_percent" => 82.0 }
        }
      )
      ProviderAvailabilityEvidence.record_codex_success!(
        user: user,
        source: "chat_turn_success",
        model: "gpt-5.5",
        observed_at: 1.minute.ago
      )
      allow(DataRootDiskUsage).to receive(:current).and_return(nil)

      alert = described_class.active_for(user: user).first

      expect(alert.id).to eq("codex_usage:#{user.id}")
      expect(alert.severity).to eq(:warn)
      expect(alert.message).to include("weekly 18% remaining")
    end

    it "uses cached provider availability for Codex usage alerts" do
      user = Factories.user
      allow(App::ProviderAvailability).to receive(:for_user).and_return(nil)
      allow(DataRootDiskUsage).to receive(:current).and_return(nil)

      described_class.active_for(user: user)

      expect(App::ProviderAvailability).to have_received(:for_user).with(user, "codex")
    end

    it "surfaces exhausted Codex usage as an alarm" do
      user = Factories.user(codex_usage_status: "exhausted", codex_usage_snapshot: {})
      allow(DataRootDiskUsage).to receive(:current).and_return(nil)

      alert = described_class.active_for(user: user).first

      expect(alert.severity).to eq(:alarm)
      expect(alert.title).to include("reached")
      expect(alert.actions).to include(
        include(text: "Resume Codex anyway", path: "/api/v1/app/credentials/override_provider_availability", destructive: true)
      )
    end

    it "hides resume override for exhausted Codex usage when provider pauses are disabled" do
      user = Factories.user(
        provider_availability_pause_thresholds: { "codex" => 0 },
        codex_usage_status: "exhausted",
        codex_usage_snapshot: {}
      )
      allow(DataRootDiskUsage).to receive(:current).and_return(nil)

      alert = described_class.active_for(user: user).first

      expect(alert.severity).to eq(:alarm)
      expect(alert.actions.map { |action| action[:text] }).not_to include("Resume Codex anyway")
    end

    it "does not surface a Codex alarm after later success suppresses bogus model-scoped evidence" do
      user = Factories.user
      repository = Factories.repository(user: user)
      job = Factories.job(repository: repository, user: user, agent_provider: "codex")
      run = Run.create!(
        job: job,
        user: user,
        step: job.latest_workflow.first_step,
        trigger_kind: "initial",
        state: "failed",
        agent_provider: "codex",
        agent_outcome: "provider_usage_limit",
        finished_at: 2.minutes.ago
      )
      ProviderAvailabilityEvidence.record_codex_invocation_failure!(
        run: run,
        model: "for",
        message: "provider usage limit exhausted for model for",
        observed_at: 2.minutes.ago
      )
      ProviderAvailabilityEvidence.record_codex_success!(
        user: user,
        source: "chat_turn_success",
        model: "gpt-5.5",
        observed_at: Time.current
      )
      allow(DataRootDiskUsage).to receive(:current).and_return(nil)

      alerts = described_class.active_for(user: user)

      expect(alerts.map(&:id)).not_to include("codex_usage:#{user.id}")
      expect(alerts.map(&:message).join).not_to include("model for")
    end

    it "surfaces warning disk usage to admins with actionable details" do
      user = Factories.user(admin: true)
      allow(DataRootDiskUsage).to receive(:current).and_return(disk_snapshot(used_percent: 86, available_bytes: 9.gigabytes, level: :warning))

      alert = described_class.active_for(user: user).first

      expect(alert.id).to eq("data_root_disk_usage")
      expect(alert.severity).to eq(:warn)
      expect(alert.title).to include("high")
      expect(alert.message).to include("86% full")
      expect(alert.message).to include("9.0GB available")
      expect(alert.message).to include("<code>/syrus-home/.syrus</code>")
      expect(alert.action_steps.join).to include("/syrus-home/.syrus/workflows")
      expect(alert.cta).to eq(text: "Open admin overview", path: "/admin")
    end

    it "surfaces a critical disk alert with workspace + resize guidance, without the misleading Docker copy" do
      user = Factories.user(admin: true)
      allow(DataRootDiskUsage).to receive(:current).and_return(disk_snapshot(used_percent: 99, available_bytes: 576.megabytes, level: :critical))

      alert = described_class.active_for(user: user).first

      expect(alert.severity).to eq(:alarm)
      expect(alert.title).to include("critical")
      expect(alert.message).to include("99% full")
      steps = alert.action_steps.join
      expect(steps).to include("/syrus-home/.syrus/workflows")
      expect(steps).to include("resize that worker's data volume")
      # On K8s (SYRUS_SQLITE unset) the per-pod story stands; the single-host
      # Docker image-prune advice is a red herring here and stays out.
      expect(alert.message).not_to match(/Docker/i)
      expect(steps).not_to match(/docker image prune/i)
    end

    it "gives single-host Docker (SYRUS_SQLITE) the image-prune guidance instead" do
      user = Factories.user(admin: true)
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("SYRUS_SQLITE").and_return("1")
      allow(DataRootDiskUsage).to receive(:current).and_return(disk_snapshot(used_percent: 92, available_bytes: 4.gigabytes, level: :critical))

      alert = described_class.active_for(user: user).first

      steps = alert.action_steps.join
      expect(alert.message).to include("single-host Docker")
      expect(steps).to include("docker image prune")
      expect(steps).to include("/syrus-home/.syrus/workflows")
    end

    it "prefers the most-full worker's own reported usage (multi-worker) and names the pod" do
      user = Factories.user(admin: true)
      InstanceVersion.create!(hostname: "worker-a", role: "worker", version: "x", started_at: Time.current,
                              last_heartbeat_at: Time.current, data_root_used_percent: 70,
                              data_root_available_bytes: 40.gigabytes, data_root_total_bytes: 100.gigabytes,
                              data_root_path: "/syrus-home/.syrus")
      InstanceVersion.create!(hostname: "worker-b", role: "worker", version: "x", started_at: Time.current,
                              last_heartbeat_at: Time.current, data_root_used_percent: 96,
                              data_root_available_bytes: 3.gigabytes, data_root_total_bytes: 100.gigabytes,
                              data_root_path: "/syrus-home/.syrus")
      # Cached single-snapshot must NOT be used when per-pod data exists.
      allow(DataRootDiskUsage).to receive(:current).and_return(nil)

      alert = described_class.active_for(user: user).first

      expect(alert.severity).to eq(:alarm)
      expect(alert.title).to include("worker-b")
      expect(alert.message).to include("96% full")
      expect(alert.message).to include("<code>worker-b</code>")
    end

    it "surfaces critical disk usage when free space is below 5GB" do
      user = Factories.user(admin: true)
      allow(DataRootDiskUsage).to receive(:current).and_return(disk_snapshot(used_percent: 80, available_bytes: 4.gigabytes, level: :critical))

      alert = described_class.active_for(user: user).first

      expect(alert.severity).to eq(:alarm)
      expect(alert.title).to include("critical")
    end

    it "does not show disk usage alerts to non-admin users" do
      Factories.user(admin: true)
      user = Factories.user(admin: false)
      allow(DataRootDiskUsage).to receive(:current).and_return(disk_snapshot(used_percent: 99, available_bytes: 1.gigabyte, level: :critical))

      expect(described_class.active_for(user: user)).to be_empty
    end
  end

  def disk_snapshot(used_percent:, available_bytes:, level:)
    instance_double(
      DataRootDiskUsage::Snapshot,
      alert?: true,
      level: level,
      used_percent: used_percent,
      available_bytes: available_bytes,
      path: "/syrus-home/.syrus"
    )
  end
end
