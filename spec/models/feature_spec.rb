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

    it "memoizes lookups in Current for the request duration" do
      Feature.create!(slug: "memoized_feature", category: "Example", name: "Memoized", enabled: true)
      Current.feature_enabled_cache = {}

      expect(Feature).to receive(:find_by).with(slug: "memoized_feature").once.and_call_original

      expect(Feature.enabled?("memoized_feature")).to be true
      expect(Feature.enabled?(:memoized_feature)).to be true
    end

    it "can clear memoized values" do
      Feature.create!(slug: "cleared_feature", category: "Example", name: "Cleared", enabled: true)
      Current.feature_enabled_cache = { "cleared_feature" => false }

      Feature.clear_enabled_cache!("cleared_feature")

      expect(Feature.enabled?("cleared_feature")).to be true
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

  describe ".video_walkthroughs_enabled?" do
    it "is false when the row is absent and follows the row when present" do
      Feature.where(slug: "video_walkthroughs").delete_all
      expect(Feature.video_walkthroughs_enabled?).to eq(false)

      feature = Feature.create!(slug: "video_walkthroughs", category: "Labs", name: "Walkthrough videos", enabled: true)
      expect(Feature.video_walkthroughs_enabled?).to eq(true)

      feature.update!(enabled: false)
      expect(Feature.video_walkthroughs_enabled?).to eq(false)
    end
  end

  describe ".coding_mode_enabled?" do
    it "returns the flag value in advanced mode" do
      Feature.create!(slug: "coding_mode", category: "Labs", name: "Coding Mode", enabled: true)
      allow(AppSetting).to receive(:simple?).and_return(false)
      expect(Feature.coding_mode_enabled?).to be true
    end

    it "is forced off in simple mode regardless of the flag" do
      Feature.create!(slug: "coding_mode", category: "Labs", name: "Coding Mode", enabled: true)
      allow(AppSetting).to receive(:simple?).and_return(true)
      expect(Feature.coding_mode_enabled?).to be false
    end
  end

  describe ".local_mode_enabled?" do
    it "returns the flag value in advanced mode" do
      Feature.create!(slug: "local_mode", category: "Labs", name: "Local Mode", enabled: true)
      allow(AppSetting).to receive(:simple?).and_return(false)
      expect(Feature.local_mode_enabled?).to be true
    end

    it "is forced off in simple mode regardless of the flag" do
      Feature.create!(slug: "local_mode", category: "Labs", name: "Local Mode", enabled: true)
      allow(AppSetting).to receive(:simple?).and_return(true)
      expect(Feature.local_mode_enabled?).to be false
    end
  end

  describe "declarations" do
    it "declares the chat_polish UI-experiment flag default-off in config/features.yml" do
      declaration = YAML.load_file(Rails.root.join("config/features.yml")).fetch("features")
                        .find { |f| f["slug"] == "chat_polish" }
      expect(declaration).to include("category" => "UI Experiments", "default" => false)
    end

    it "declares the video_walkthroughs labs flag default-off in config/features.yml" do
      declaration = YAML.load_file(Rails.root.join("config/features.yml")).fetch("features")
                        .find { |f| f["slug"] == "video_walkthroughs" }
      expect(declaration).to include("category" => "Labs", "default" => false)
    end

    it "declares the performance logging operations flag default-off in config/features.yml" do
      declaration = YAML.load_file(Rails.root.join("config/features.yml")).fetch("features")
                        .find { |f| f["slug"] == "performance_logging" }
      expect(declaration).to include("category" => "Operations", "default" => false)
    end

    it "declares the unified work-engine reconciler operations flag default-off in config/features.yml" do
      declaration = YAML.load_file(Rails.root.join("config/features.yml")).fetch("features")
                        .find { |f| f["slug"] == WorkEngine::Gate::FEATURE_SLUG }
      expect(declaration).to include("category" => "Operations", "default" => false)
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
