require "rails_helper"

RSpec.describe SpendingInsights::SidebarPages do
  it "declares the spending sidebar page" do
    expect(described_class.sidebar_pages).to contain_exactly(
      include(
        id: "spending.dashboard",
        label: "Spending",
        label_key: "spending:nav_spending",
        path: "/insights/spending",
        paths: [ "/insights/spending" ],
        component: "spending_insights/SpendingInsights",
        icon: "spending"
      )
    )
  end
end
