require "rails_helper"

RSpec.describe ChatMediaRef do
  describe ".valid?" do
    it "accepts snapshot, chat_image, and preview_panel_version refs" do
      expect(described_class.valid?("snapshot:1")).to be true
      expect(described_class.valid?("chat_image:42")).to be true
      expect(described_class.valid?("preview_panel_version:7")).to be true
    end

    it "rejects unknown kinds and malformed refs" do
      expect(described_class.valid?("bogus:1")).to be false
      expect(described_class.valid?("preview_panel_version:abc")).to be false
      expect(described_class.valid?("preview_panel_version")).to be false
    end
  end

  describe ".split" do
    it "splits a preview_panel_version ref into kind and integer id" do
      expect(described_class.split("preview_panel_version:7")).to eq([ "preview_panel_version", 7 ])
    end
  end
end
