require "rails_helper"

RSpec.describe Coworkers::MetricsDashboardTabs do
  it "contributes only coworker-owned metrics grouped by handle" do
    tab = described_class.metrics_dashboard_tabs.fetch(0)

    expect(tab).to include(id: "coworkers", label: "Coworkers")
    expect(tab.fetch(:panels).pluck(:metric)).to all(start_with("syrus_coworkers_"))
    expect(tab.fetch(:panels).pluck(:group_by)).to all(eq("coworker"))
  end
end
