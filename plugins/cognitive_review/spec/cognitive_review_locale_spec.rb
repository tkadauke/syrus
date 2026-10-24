require "rails_helper"
require "json"

RSpec.describe "Cognitive Review frontend locales", type: :unit do
  let(:root) { Rails.root.join("plugins/cognitive_review/app/frontend/i18n/locales") }
  def locale(name) = JSON.parse(File.read(root.join(name, "cognitive_review.json")))

  it "uses native German orthography and keeps Latin copy free of English instructions" do
    expect(locale("de").dig("actions", "feedback_reply_hint")).to include("Fügt", "ausgewählte")
    expect(locale("de").dig("panel", "rollup_summary")).to include("bestätigt")
    expect(locale("la").dig("actions", "discussion_prompt")).to eq("Promptum initiale")
    expect(locale("la").dig("actions", "feedback_reply_hint")).to include("Feedback mitte")
    expect(locale("la").dig("actions", "feedback_reply_hint")).not_to include("Submit Feedback")
  end
end
