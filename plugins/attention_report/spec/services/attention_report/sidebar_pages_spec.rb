require "rails_helper"

RSpec.describe AttentionReport::SidebarPages do
  it "registers the attention report sidebar page" do
    expect(described_class.sidebar_pages).to contain_exactly(
      include(
        id: "attention_report.dashboard",
        path: "/insights/attention",
        paths: [ "/insights/attention" ],
        component: "attention_report/AttentionReport"
      )
    )
  end
end
