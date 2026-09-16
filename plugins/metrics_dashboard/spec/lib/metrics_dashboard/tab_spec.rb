require "rails_helper"

RSpec.describe MetricsDashboard::Tab do
  let(:provider) { Class.new { include MetricsDashboard::Tab } }

  it "raises NotImplementedError for metrics_dashboard_tabs by default" do
    expect { provider.metrics_dashboard_tabs }.to raise_error(NotImplementedError, /must implement \.metrics_dashboard_tabs/)
  end

  it "extends including classes with the class method" do
    expect(provider).to respond_to(:metrics_dashboard_tabs)
  end
end
