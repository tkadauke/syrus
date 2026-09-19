require "rails_helper"

RSpec.describe ChatDraftContent, type: :model do
  describe ".from_content" do
    it "falls back to legacy content when text is blank" do
      draft = described_class.from_content({ "text" => "", "content" => "actual body" })

      expect(draft.text).to eq("actual body")
    end
  end
end
