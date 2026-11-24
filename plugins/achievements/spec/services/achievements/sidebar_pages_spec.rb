require "rails_helper"

RSpec.describe Achievements::SidebarPages do
  it "contributes the collection page only for a signed-in user while enabled" do
    allow(Achievements).to receive(:enabled?).and_return(true)
    expect(described_class.sidebar_pages).to eq([])

    Current.api_user = Factories.user
    begin
      page = described_class.sidebar_pages.first
      expect(page).to include(path: "/achievements", component: "achievements/Achievements")
    ensure
      Current.reset
    end

    allow(Achievements).to receive(:enabled?).and_return(false)
    expect(described_class.sidebar_pages).to eq([])
  end
end
