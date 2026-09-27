require "rails_helper"

RSpec.describe SystemAlertDeliveryJob, type: :job do
  it "delivers alerts from the background alert pipeline" do
    alerts = [ instance_double(SystemAlerts::Alert) ]
    allow(SystemAlertDelivery).to receive(:configured?).and_return(true)
    allow(SystemAlerts).to receive(:outbound_alerts).and_return(alerts)
    allow(SystemAlertDelivery).to receive(:deliver)

    described_class.perform_now

    expect(SystemAlertDelivery).to have_received(:deliver).with(alerts)
  end

  it "does not evaluate alert sources when no outbound sink is configured" do
    allow(SystemAlertDelivery).to receive(:configured?).and_return(false)
    allow(SystemAlerts).to receive(:outbound_alerts)

    described_class.perform_now

    expect(SystemAlerts).not_to have_received(:outbound_alerts)
  end

  it "runs on the control-plane queue" do
    expect(described_class.new.queue_name).to eq("control_plane")
  end
end
