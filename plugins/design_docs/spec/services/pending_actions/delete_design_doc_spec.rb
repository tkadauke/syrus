require "rails_helper"

RSpec.describe PendingActions::DeleteDesignDoc do
  describe "presentation" do
    it "labels and details the action from the design doc reference and confirmation reason" do
      action = ChatPendingAction.new(
        action: "delete_design_doc",
        payload: { "design_doc_id" => 29, "doc_ref" => "DOC-29", "title" => "Launch Checklist", "confirmation_reason" => "Superseded by DOC-40." }
      )
      presenter = described_class.new(action)

      expect(presenter.presentation_label).to eq("Archive DOC-29")
      expect(presenter.presentation_detail).to eq("Launch Checklist\nSuperseded by DOC-40.")
    end

    it "falls back to a DOC-<id> label when doc_ref is missing" do
      action = ChatPendingAction.new(action: "delete_design_doc", payload: { "design_doc_id" => 7 })

      expect(described_class.new(action).presentation_label).to eq("Archive DOC-7")
    end
  end
end
