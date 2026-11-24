require "rails_helper"

RSpec.describe PluginDesiredState::Convergence do
  let(:now) { Time.zone.parse("2026-11-18 12:00:00") }

  before do
    allow(PluginDesiredState::Publisher).to receive(:publish!)
    release = PluginRelease.create!(name: "weather", version: "1.0.0", content_digest: Digest::SHA256.hexdigest("archive"),
      source: "upload", trust_label: "unsigned_local", size_bytes: 7)
    PluginArtifacts.store!(release, StringIO.new("archive"))
    PluginInstallation.create!(plugin_name: "weather", plugin_release: release, roles: [ "web" ])
  end

  def make_built_in_only!
    PluginInstallation.destroy_all
    release = PluginRelease.create!(name: "core_thing", version: "1.0.0", content_digest: "b" * 64,
      source: "bundled", trust_label: "official", size_bytes: 0)
    PluginInstallation.create!(plugin_name: "core_thing", plugin_release: release)
  end

  def alert_for(user)
    allow(DataRootDiskUsage).to receive(:current).and_return(nil)
    SystemAlerts.active_for(user:).find { |candidate| candidate.id == "plugin_fleet_divergence" }
  end

  it "raises no alert for a built-in-only install with a stale heartbeat and historical revision" do
    make_built_in_only!
    state = PluginDesiredState.current
    state.update!(revision: 7)
    state.update_column(:updated_at, now - 1.hour)
    create_process("stale", 3, now - 1.hour, started_at: now - 2.hours)

    expect(described_class.new(state:, now:).prolonged_divergence?).to be(false)
    expect(alert_for(Factories.user(admin: true))).to be_nil
  end

  it "raises no alert once the external desired set is removed" do
    PluginInstallation.sole.update!(enabled_for_sync: false)
    state = PluginDesiredState.current
    state.update!(revision: 9)
    state.update_column(:updated_at, now - 1.hour)
    create_process("stale", 3, now - 1.hour, started_at: now - 2.hours)

    expect(described_class.new(state:, now:).prolonged_divergence?).to be(false)
  end

  it "still flags an unreachable process with an enabled external release" do
    state = PluginDesiredState.current
    state.update!(revision: 3)
    state.update_column(:updated_at, now - 1.hour)
    create_process("gone", 3, now - 1.hour, started_at: now - 2.hours)

    expect(described_class.new(state:, now: now - 11.minutes, threshold: 10.minutes).prolonged_divergence?).to be(false)
    expect(described_class.new(state:, now:, threshold: 10.minutes).prolonged_divergence?).to be(true)
  end

  it "classifies converged, pending, behind, ahead, and unreachable processes" do
    desired_digest = Digest::SHA256.hexdigest(JSON.generate([
      { "name" => "weather", "version" => "1.0.0", "digest" => Digest::SHA256.hexdigest("archive"), "size" => 7 }
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
    described_class.new(state:, now: now - 11.minutes, threshold: 10.minutes).as_json

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
    described_class.new(state:, now: 11.minutes.ago, threshold: 10.minutes).as_json
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("SYRUS_PLUGIN_DIVERGENCE_THRESHOLD_SECONDS", anything).and_return("600")
    admin = Factories.user(admin: true)
    allow(DataRootDiskUsage).to receive(:current).and_return(nil)
    allow(SystemAlertDelivery).to receive(:configured?).and_return(true)
    allow_any_instance_of(SystemAlertDelivery).to receive(:deliver_to_sinks)

    alert = SystemAlerts.active_for(user: admin).find { |candidate| candidate.id == "plugin_fleet_divergence" }
    SystemAlertDelivery.deliver([ alert ])

    expect(alert.cta).to eq(text: "Review plugin convergence", path: "/admin/plugins")
    expect(SystemAlertNotification.find_by!(alert_id: "plugin_fleet_divergence").payload.dig("cta", "url")).to end_with("/admin/plugins")
  end

  describe "divergence episodes" do
    let(:state) { PluginDesiredState.current }

    before do
      state.update!(revision: 2)
      state.update_column(:updated_at, now - 2.hours)
    end

    def prolonged?(at) = described_class.new(state: PluginDesiredState.current, now: at, threshold: 5.minutes).prolonged_divergence?

    it "gives a newly observed mismatch the full grace period even when records are old" do
      create_process("behind", 1, now, started_at: now - 3.hours)

      expect(prolonged?(now)).to be(false)
      expect(prolonged?(now + 4.minutes)).to be(false)
      expect(prolonged?(now + 5.minutes)).to be(true)
    end

    it "clears the episode on convergence so a later mismatch gets a fresh grace period" do
      process = create_process("behind", 1, now, started_at: now - 3.hours)
      expect(prolonged?(now)).to be(false)

      process.update!(plugin_set_digest: desired_digest, plugin_set_revision: 2, last_heartbeat_at: now + 3.minutes)
      expect(prolonged?(now + 3.minutes)).to be(false)
      expect(PluginDesiredState.current.divergence_episodes).to eq({})

      process.update!(plugin_set_digest: nil, plugin_set_revision: 1, last_heartbeat_at: now + 9.minutes)
      expect(prolonged?(now + 9.minutes)).to be(false)
      expect(prolonged?(now + 13.minutes)).to be(false)
      expect(prolonged?(now + 14.minutes)).to be(true)
    end

    it "restarts the episode when the desired plugin-set identity changes" do
      create_process("behind", 1, now, started_at: now - 3.hours)
      expect(prolonged?(now)).to be(false)

      release = PluginRelease.create!(name: "weather", version: "2.0.0", content_digest: Digest::SHA256.hexdigest("archive2"),
        source: "upload", trust_label: "unsigned_local", size_bytes: 8)
      PluginArtifacts.store!(release, StringIO.new("archive2"))
      PluginInstallation.sole.update!(plugin_release: release)
      InstanceVersion.update_all(last_heartbeat_at: now + 6.minutes)
      expect(prolonged?(now + 6.minutes)).to be(false)
      InstanceVersion.update_all(last_heartbeat_at: now + 11.minutes)
      expect(prolonged?(now + 11.minutes)).to be(true)
    end

    it "drops the episode when the process leaves the cohort" do
      process = create_process("behind", 1, now, started_at: now - 3.hours)
      expect(prolonged?(now)).to be(false)
      process.update!(finished_at: now + 1.minute)
      expect(prolonged?(now + 2.minutes)).to be(false)
      expect(PluginDesiredState.current.divergence_episodes).to eq({})
    end

    it "keeps the alert episode key stable when the earliest sustained process recovers but another remains" do
      first = create_process("first", 1, now, started_at: now - 3.hours)
      expect(prolonged?(now)).to be(false)
      create_process("second", 1, now + 2.minutes, started_at: now - 3.hours)
      InstanceVersion.update_all(last_heartbeat_at: now + 6.minutes)
      key_for = ->(at) { described_class.new(state: PluginDesiredState.current, now: at, threshold: 5.minutes).prolonged_episode_key }
      expect(key_for.call(now + 2.minutes)).to be_nil
      expect(key_for.call(now + 6.minutes)).to eq(now.to_i)

      first.update!(plugin_set_digest: desired_digest, plugin_set_revision: 2, last_heartbeat_at: now + 7.minutes)
      InstanceVersion.where.not(id: first.id).update_all(last_heartbeat_at: now + 7.minutes)

      expect(key_for.call(now + 7.minutes)).to eq(now.to_i)
    end

    it "keeps reporting transient states on rows before the alarm is sustained" do
      create_process("behind", 1, now)
      row = described_class.new(state: PluginDesiredState.current, now:, threshold: 5.minutes).as_json.fetch(:processes).sole

      expect(row).to include(state: "behind", diverged_too_long: false)
    end

    def desired_digest
      Digest::SHA256.hexdigest(JSON.generate([
        { "name" => "weather", "version" => "1.0.0", "digest" => Digest::SHA256.hexdigest("archive"), "size" => 7 }
      ]))
    end
  end

  def create_process(hostname, revision, heartbeat, digest: nil, started_at: now - 5.minutes)
    InstanceVersion.create!(hostname:, role: "web", version: "sha", started_at:, last_heartbeat_at: heartbeat,
      plugin_set_revision: revision, plugin_set_digest: digest, plugin_set_details: { "plugins" => [] })
  end
end
