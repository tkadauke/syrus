require "rails_helper"

RSpec.describe PluginDesiredState::RestartStatus do
  it "reports pending, restarted, and stuck processes for the applied revision" do
    now = Time.current
    state = PluginDesiredState.current
    state.update!(revision: 7, apply_revision: 7, apply_requested_at: now,
      apply_processes: [ { hostname: "web-a", role: "web" }, { hostname: "worker-a", role: "worker" } ])
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

  it "keeps a stopped process visible and marks it stuck when no replacement starts" do
    now = Time.current
    state = PluginDesiredState.current
    state.update!(revision: 7, apply_revision: 7,
      apply_requested_at: now - described_class::STUCK_AFTER - 1.second,
      apply_processes: [ { hostname: "web-a", role: "web" } ])
    InstanceVersion.create!(hostname: "web-a", role: "web", version: "sha", started_at: now - 10.minutes,
      last_heartbeat_at: now - 6.minutes, finished_at: now - 5.minutes, plugin_set_revision: 6)

    status = described_class.new(state: state, now: now).as_json.fetch(:processes).sole

    expect(status).to include("hostname" => "web-a", "role" => "web", "restart_state" => "stuck")
  end
end
