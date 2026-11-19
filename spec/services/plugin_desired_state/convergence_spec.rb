require "rails_helper"

RSpec.describe PluginDesiredState::Convergence do
  let(:now) { Time.zone.parse("2026-11-18 12:00:00") }

  before do
    allow(PluginDesiredState::Publisher).to receive(:publish!)
    release = PluginRelease.create!(name: "weather", version: "1.0.0", content_digest: "a" * 64,
      source: "bundled", trust_label: "official", size_bytes: 0)
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

  it "loads process and plugin data in a fixed number of queries for a cohort" do
    state = PluginDesiredState.current
    state.update!(revision: 0, apply_processes: 4.times.map { |index| { "hostname" => "recorded-#{index}", "role" => "web" } })
    4.times do |index|
      process = create_process("recorded-#{index}", 1, now)
      process.update!(finished_at: now - 1.minute)
    end

    queries = []
    result = nil
    callback = lambda do |_name, _started, _finished, _id, payload|
      queries << payload[:sql].to_s if payload[:sql].to_s.match?(/\ASELECT/i)
    end

    ActiveRecord::Base.uncached do
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        result = described_class.new(state:, now:).as_json
      end
    end

    expect(result.fetch(:processes).pluck(:state)).to contain_exactly(*([ "ahead" ] * 4))
    expect(queries.grep(/\binstance_versions\b/i).size).to eq(2)
    expect(queries.grep(/\bplugin_installations\b/i).size).to eq(1)
    expect(queries.grep(/\bplugin_releases\b/i).size).to eq(1)
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
