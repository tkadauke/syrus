require "rails_helper"

RSpec.describe Coworkers::MetricsDashboardTabs do
  it "contributes only coworker-owned metrics grouped by handle" do
    tab = described_class.metrics_dashboard_tabs.fetch(0)

    expect(tab).to include(id: "coworkers", label: "Coworkers")
    expect(tab.fetch(:summary)).to include(title: "Coworker health")
    expect(tab.fetch(:panels).pluck(:metric)).to all(start_with("syrus_coworkers_"))
    expect(tab.fetch(:panels).pluck(:group_by)).to all(eq("coworker"))
    expect(tab.fetch(:panels).pluck(:key)).to all(start_with("coworkers_"))
  end

  it "localizes the summary contract in every backend locale" do
    summaries = %i[en de la].to_h { |locale| [ locale, I18n.with_locale(locale) { described_class.metrics_dashboard_tabs.fetch(0) } ] }

    expect(summaries[:en].dig(:summary, :columns).pluck(:label)).to include("Journaling state")
    expect(summaries[:de].dig(:summary, :columns).pluck(:label)).to include("Journalstatus")
    expect(summaries[:la].dig(:summary, :columns).pluck(:label)).to include("Status commentarii")
    expect(summaries.values.flatten.to_s).not_to include("translation missing")
  end
end
