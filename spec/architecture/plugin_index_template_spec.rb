require "rails_helper"

RSpec.describe "plugin index repository template" do
  it "validates submissions against the base revision trust store" do
    workflow = Rails.root.join("templates/plugin-index/.github/workflows/check-submission.yml").read

    expect(workflow).to include('git show "${{ github.event.pull_request.base.sha }}:trust-store.json"')
    expect(workflow).to include('plugin index-check "$entry" --trust-store "$trusted_store"')
    expect(workflow).not_to include('plugin index-check "$entry" --trust-store trust-store.json')
  end
end
