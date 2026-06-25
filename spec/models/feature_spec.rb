require "rails_helper"

RSpec.describe Feature, type: :model do
  it "validates required metadata" do
    feature = Feature.new

    expect(feature).not_to be_valid
    expect(feature.errors[:slug]).to include("can't be blank")
    expect(feature.errors[:category]).to include("can't be blank")
    expect(feature.errors[:name]).to include("can't be blank")
  end

  it "requires unique slugs" do
    Feature.create!(slug: "v2_sidebar", category: "Navigation", name: "V2 Sidebar")

    duplicate = Feature.new(slug: "v2_sidebar", category: "Navigation", name: "Duplicate")

    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:slug]).to include("has already been taken")
  end

  describe ".enabled?" do
    it "returns the live enabled value for string or symbol slugs" do
      Feature.create!(slug: "enabled_feature", category: "Example", name: "Enabled", enabled: true)
      Feature.create!(slug: "disabled_feature", category: "Example", name: "Disabled", enabled: false)

      expect(Feature.enabled?("enabled_feature")).to be true
      expect(Feature.enabled?(:enabled_feature)).to be true
      expect(Feature.enabled?("disabled_feature")).to be false
    end

    it "returns false for unknown slugs" do
      expect(Feature.enabled?("missing")).to be false
    end
  end
end
