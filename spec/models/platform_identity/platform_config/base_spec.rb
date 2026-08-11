require "rails_helper"

RSpec.describe PlatformIdentity::PlatformConfig::Base do
  describe ".for" do
    it "returns a Telegram config for 'telegram'" do
      expect(described_class.for("telegram")).to be_a(PlatformIdentity::PlatformConfig::Telegram)
    end

    it "returns a Slack config for 'slack'" do
      expect(described_class.for("slack")).to be_a(PlatformIdentity::PlatformConfig::Slack)
    end

    it "returns Unconfigured for a platform with no dedicated config class" do
      expect(described_class.for("discord")).to be_a(PlatformIdentity::PlatformConfig::Unconfigured)
    end
  end

  describe PlatformIdentity::PlatformConfig::Unconfigured do
    it "reports not configured" do
      expect(described_class.new.configured?).to be false
    end

    it "returns generic instructions" do
      expect(described_class.new.instructions("tok")).to eq({ text: "This platform is not yet configured." })
    end
  end
end
