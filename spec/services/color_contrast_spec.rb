require "rails_helper"

RSpec.describe ColorContrast do
  describe ".ratio" do
    it "returns 21:1 for pure black on pure white" do
      expect(described_class.ratio("#000000", "#ffffff")).to be_within(0.01).of(21.0)
    end

    it "returns 1:1 for identical colors" do
      expect(described_class.ratio("#123456", "#123456")).to eq(1.0)
    end

    it "is symmetric regardless of argument order" do
      expect(described_class.ratio("#047857", "#ffffff")).to eq(described_class.ratio("#ffffff", "#047857"))
    end

    it "matches a known real-world pairing (emerald-700 on white)" do
      expect(described_class.ratio("#047857", "#ffffff")).to be_within(0.05).of(5.48)
    end
  end

  describe ".blend" do
    it "returns the base color unchanged at alpha 0" do
      expect(described_class.blend("#ffffff", "#047857", 0)).to eq("#ffffff")
    end

    it "returns the tint color unchanged at alpha 1" do
      expect(described_class.blend("#ffffff", "#047857", 1)).to eq("#047857")
    end

    it "blends proportionally at a partial alpha" do
      expect(described_class.blend("#000000", "#ffffff", 0.5)).to eq("#808080")
    end
  end
end
