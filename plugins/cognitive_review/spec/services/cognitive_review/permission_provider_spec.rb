require "rails_helper"

RSpec.describe CognitiveReview::PermissionProvider do
  it "authorizes review-note submission through an explicit bounded descriptor" do
    descriptor = CognitiveReview::McpToolSet.tool_definitions.first.fetch(:capability_descriptor)

    expect(descriptor).to be(described_class.capability_descriptor(described_class::OPERATION))
    # The reviewer's own notes are bounded workflow output: essential.
    expect(descriptor).to have_attributes(effects: [ :internal_write ], essential: true)
    expect(descriptor.defaults.values.uniq).to eq([ :ask ])
  end
end
