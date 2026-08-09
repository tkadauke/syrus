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
