require "rails_helper"

RSpec.describe PluginDesiredState::RestartStatus do
  it "reports pending, restarted, and stuck processes for the applied revision" do
    now = Time.current
    state = PluginDesiredState.current
    state.update!(revision: 7, apply_revision: 7, apply_requested_at: now)
    pending = InstanceVersion.create!(hostname: "web-a", role: "web", version: "sha", started_at: now,
      last_heartbeat_at: now, plugin_set_revision: 6)
    restarted = InstanceVersion.create!(hostname: "worker-a", role: "worker", version: "sha", started_at: now,
      last_heartbeat_at: now, plugin_set_revision: 7)

    statuses = described_class.new(state: state, now: now).as_json.fetch(:processes).index_by { |row| row.fetch("hostname") }
    expect(statuses.fetch(pending.hostname).fetch("restart_state")).to eq("pending_restart")
    expect(statuses.fetch(restarted.hostname).fetch("restart_state")).to eq("restarted")

    state.update!(apply_requested_at: now - described_class::STUCK_AFTER - 1.second)
    statuses = described_class.new(state: state, now: now).as_json.fetch(:processes).index_by { |row| row.fetch("hostname") }
    expect(statuses.fetch(pending.hostname).fetch("restart_state")).to eq("stuck")
  end
end
