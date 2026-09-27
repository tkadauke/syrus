require "rails_helper"

RSpec.describe OperatorBriefing::SidebarPages do
  it "registers the top-level briefing sidebar page" do
    expect(described_class.sidebar_pages).to contain_exactly(
      include(
        id: "operator_briefing.dashboard",
        path: "/briefing",
        paths: [ "/briefing", "/briefing/history" ],
        component: "operator_briefing/Briefing"
      )
    )
  end
end
