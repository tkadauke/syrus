require "rails_helper"

RSpec.describe TeamDirectory::SidebarPages do
  it "offers no directory entry on a single-operator instance" do
    User.destroy_all
    Factories.user

    expect(described_class.sidebar_pages).to eq([])
  end

  it "offers the directory once a second operator exists" do
    Factories.user
    Factories.user

    page = described_class.sidebar_pages.sole

    expect(page[:path]).to eq("/profiles")
    expect(page[:component]).to eq("team_directory/TeamDirectory")
    expect(page[:label_key]).to eq("team_directory:nav_team")
  end

  it "is served through the sidebar pages payload" do
    Factories.user
    Factories.user

    ids = App::SidebarPagesPayload.new.as_json[:pages].map { |page| page[:id] }

    expect(ids).to include("team_directory.index")
  end
end
