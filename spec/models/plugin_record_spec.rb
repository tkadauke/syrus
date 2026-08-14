require "rails_helper"

RSpec.describe PluginRecord, :reset_plugin_registry do
  around do |ex|
    Syrus::PluginRegistry.reset!
    ex.run
    Syrus::PluginRegistry.reset!
  end

  let(:callbacks_class) { Class.new { include Syrus::Plugin::Callbacks } }

  before do
    Syrus::PluginRegistry.register(
      name: "lifecycle_plugin",
      version: "1.0.0",
      provides: { callbacks: callbacks_class }
    )
  end

  describe ".search" do
    before do
      Syrus::PluginRegistry.register(
        name: "weather-plugin",
        display_name: "Weather Radar",
        version: "1.0.0",
        description: "Watches storms roll in.",
        category: "monitoring"
      )
      Syrus::PluginRegistry.register(
        name: "ticket-plugin",
        display_name: "Ticket Sync",
        version: "1.0.0",
        description: "Keeps issues in sync.",
        category: "integration"
      )
    end

    it "matches on description text" do
      expect(PluginRecord.search("storms").pluck(:name)).to eq([ "weather-plugin" ])
    end

    it "matches on display_name text" do
      expect(PluginRecord.search("Ticket").pluck(:name)).to eq([ "ticket-plugin" ])
    end

    it "matches on category text" do
      expect(PluginRecord.search("monitoring").pluck(:name)).to eq([ "weather-plugin" ])
    end

    it "returns no matches for an unrelated query" do
      expect(PluginRecord.search("nonexistent")).to be_empty
    end

    it "returns every record for a blank query" do
      expect(PluginRecord.search("").pluck(:name)).to include("weather-plugin", "ticket-plugin", "lifecycle_plugin")
    end

    it "returns every record for a nil query" do
      expect(PluginRecord.search(nil).pluck(:name)).to include("weather-plugin", "ticket-plugin", "lifecycle_plugin")
    end
  end

  describe "after_commit lifecycle job enqueue" do
    let(:record) { PluginRecord.find_by!(name: "lifecycle_plugin") }

    it "enqueues PluginLifecycleJob with on_enable when enabled becomes true" do
      record.update!(enabled: false)

      expect {
        record.update!(enabled: true)
      }.to have_enqueued_job(PluginLifecycleJob).with("lifecycle_plugin", "on_enable")
    end

    it "enqueues PluginLifecycleJob with on_disable when enabled becomes false" do
      expect {
        record.update!(enabled: false)
      }.to have_enqueued_job(PluginLifecycleJob).with("lifecycle_plugin", "on_disable")
    end

    it "does not enqueue PluginLifecycleJob when enabled does not change" do
      expect {
        record.update!(config: { "foo" => "bar" })
      }.not_to have_enqueued_job(PluginLifecycleJob)
    end

    it "does not enqueue PluginLifecycleJob for plugins without a callback provider" do
      Syrus::PluginRegistry.register(name: "no_callbacks_plugin", version: "1.0.0")
      plain_record = PluginRecord.find_by!(name: "no_callbacks_plugin")

      expect {
        plain_record.update!(enabled: false)
      }.not_to have_enqueued_job(PluginLifecycleJob)
    end

    it "uses the manifest home_queue when it is not :default" do
      Syrus::PluginRegistry.register(
        name: "queued_plugin",
        version: "1.0.0",
        home_queue: :control_plane,
        provides: { callbacks: callbacks_class }
      )
      queued_record = PluginRecord.find_by!(name: "queued_plugin")

      expect {
        queued_record.update!(enabled: false)
      }.to have_enqueued_job(PluginLifecycleJob).on_queue("control_plane")
    end
  end
end
