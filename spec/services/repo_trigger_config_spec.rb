require "rails_helper"

RSpec.describe RepoTriggerConfig do
  describe ".from_yaml" do
    it "enables mention and assignment triggers by default" do
      config = described_class.from_yaml(nil)

      expect(config.mentions?).to be true
      expect(config.assignments?).to be true
    end

    it "allows .syrus.yml to opt out of mention triggers" do
      config = described_class.from_yaml(<<~YAML)
        triggers:
          mentions: false
      YAML

      expect(config.mentions?).to be false
      expect(config.assignments?).to be true
    end

    it "allows .syrus.yml to opt out of assignment triggers" do
      config = described_class.from_yaml(<<~YAML)
        triggers:
          assignments: false
      YAML

      expect(config.mentions?).to be true
      expect(config.assignments?).to be false
    end

    it "accepts singular trigger keys as aliases" do
      config = described_class.from_yaml(<<~YAML)
        triggers:
          mention: false
          assignment: false
      YAML

      expect(config.mentions?).to be false
      expect(config.assignments?).to be false
    end

    it "falls back to defaults when the YAML root is not a map" do
      config = described_class.from_yaml("- not\n- a\n- map\n")

      expect(config.mentions?).to be true
      expect(config.assignments?).to be true
    end
  end
end
