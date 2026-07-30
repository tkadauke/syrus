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

      alert = described_class.active_for(user: user).first

      expect(alert.id).to eq("codex_usage:#{user.id}")
      expect(alert.severity).to eq(:warn)
      expect(alert.title).to include("low")
      expect(alert.message).to include("5h 12% remaining")
      expect(alert.message).to include("weekly 88% remaining")
      expect(alert.cta).to eq(text: "Open credentials", path: "/credentials")
    end

    it "surfaces exhausted Codex usage as an alarm" do
      user = Factories.user(codex_usage_status: "exhausted", codex_usage_snapshot: {})
      allow(DataRootDiskUsage).to receive(:current).and_return(nil)

      alert = described_class.active_for(user: user).first

      expect(alert.severity).to eq(:alarm)
      expect(alert.title).to include("reached")
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
