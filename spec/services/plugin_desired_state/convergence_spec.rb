require "rails_helper"

RSpec.describe PluginDesiredState::Convergence do
  let(:now) { Time.zone.parse("2026-11-18 12:00:00") }

  before do
    allow(PluginDesiredState::Publisher).to receive(:publish!)
    release = PluginRelease.create!(name: "weather", version: "1.0.0", content_digest: "a" * 64,
      source: "bundled", trust_label: "reviewed", size_bytes: 0)
    PluginInstallation.create!(plugin_name: "weather", plugin_release: release, roles: [ "web" ])
  end

  it "classifies converged, pending, behind, ahead, and unreachable processes" do
    desired_digest = Digest::SHA256.hexdigest(JSON.generate([
      { "name" => "weather", "version" => "1.0.0", "digest" => "a" * 64, "size" => 0 }
    ]))
    state = PluginDesiredState.current
    state.update!(revision: 4, apply_revision: 4, apply_requested_at: now - 1.minute)
    create_process("converged", 4, now, digest: desired_digest)
    create_process("pending", 3, now)
    create_process("ahead", 5, now)
    create_process("unreachable", 3, now - 3.minutes)

    rows = described_class.new(state:, now:).as_json.fetch(:processes).index_by { |row| row[:hostname] }

    expect(rows.transform_values { |row| row[:state] }).to include(
      "converged" => "converged", "pending" => "pending_restart", "ahead" => "ahead", "unreachable" => "unreachable"
    )
  end

  it "marks divergence beyond the configurable threshold" do
    state = PluginDesiredState.current
    state.update!(revision: 2, apply_requested_at: nil)
    state.update_column(:updated_at, now - 11.minutes)
    create_process("behind", 1, now - 1.minute, started_at: now - 20.minutes)

    row = described_class.new(state:, now:, threshold: 10.minutes).as_json.fetch(:processes).sole

    expect(row).to include(state: "behind", diverged_too_long: true)
  end

  it "emits the existing operational alert record when divergence persists" do
    state = PluginDesiredState.current
    state.update!(revision: 2)
    state.update_column(:updated_at, now - 11.minutes)
    create_process("behind-alert", 1, now - 1.minute, started_at: now - 20.minutes)
    admin = Factories.user(admin: true)
    allow(DataRootDiskUsage).to receive(:current).and_return(nil)
    allow(SystemAlertDelivery).to receive(:configured?).and_return(true)
    allow_any_instance_of(SystemAlertDelivery).to receive(:deliver_to_sinks)

    alert = SystemAlerts.active_for(user: admin).find { |candidate| candidate.id == "plugin_fleet_divergence" }
    SystemAlertDelivery.deliver([ alert ])

    expect(alert.cta).to eq(text: "Review plugin convergence", path: "/admin/plugins")
    expect(SystemAlertNotification.find_by!(alert_id: "plugin_fleet_divergence").payload.dig("cta", "url")).to end_with("/admin/plugins")
  end

  def create_process(hostname, revision, heartbeat, digest: nil, started_at: now - 5.minutes)
    InstanceVersion.create!(hostname:, role: "web", version: "sha", started_at:, last_heartbeat_at: heartbeat,
      plugin_set_revision: revision, plugin_set_digest: digest, plugin_set_details: { "plugins" => [] })
  end
end
