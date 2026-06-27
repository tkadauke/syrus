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

  describe ".terminal_enabled?" do
    it "returns the live terminal flag state" do
      Feature.find_or_create_by!(slug: "terminal") do |feature|
        feature.category = "labs"
        feature.name = "Terminal"
      end.update!(enabled: true)

      expect(Feature.terminal_enabled?).to be true
    end
  end

  describe "seed data" do
    it "creates the terminal feature idempotently" do
      Feature.where(slug: "terminal").delete_all

      Rails.application.load_seed
      Rails.application.load_seed

      features = Feature.where(slug: "terminal")
      expect(features.count).to eq(1)
      expect(features.first).to have_attributes(
        category: "labs",
        name: "Terminal",
        enabled: false
      )
    end
  end
end
