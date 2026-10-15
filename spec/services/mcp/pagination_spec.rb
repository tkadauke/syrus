require "rails_helper"

RSpec.describe Mcp::Pagination do
  describe ".normalize_page" do
    it "preserves ordinary page numbers, including pages beyond the result set" do
      expect(described_class.normalize_page(37)).to eq(37)
    end

    it "normalizes missing and non-positive page numbers to the first page" do
      expect(described_class.normalize_page(nil)).to eq(1)
      expect(described_class.normalize_page(0)).to eq(1)
      expect(described_class.normalize_page(-10)).to eq(1)
    end

    it "caps huge integers before they can become SQL offsets" do
      expect(described_class.normalize_page(10**100)).to eq(described_class::MAX_PAGE)
    end
  end
end
