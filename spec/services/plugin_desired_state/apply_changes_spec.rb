require "rails_helper"

RSpec.describe PluginDesiredState::ApplyChanges do
  it "marks the desired revision pending and requests a graceful restart" do
    state = PluginDesiredState.current
    state.update!(revision: 4)
    restart = instance_double(Admin::RestartService)
    InstanceVersion.create!(hostname: "web-a", role: "web", version: "sha", started_at: Time.current,
      last_heartbeat_at: Time.current)
    allow(Admin::RestartService).to receive(:new).and_return(restart)
    expect(restart).to receive(:request).with(component: "all", force: true, source: "plugin_apply")

    described_class.new(actor: Factories.user).call

    expect(state.reload).to have_attributes(apply_revision: 4, apply_processes: [ { "hostname" => "web-a", "role" => "web" } ])
    expect(state.apply_requested_at).to be_present
  end
end
