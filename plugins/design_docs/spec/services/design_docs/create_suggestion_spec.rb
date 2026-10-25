require "rails_helper"

RSpec.describe DesignDocs::CreateSuggestion do
  let(:owner) { Factories.user(email_address: "owner@example.com") }
  let(:collaborator) { Factories.user(email_address: "collaborator@example.com") }
  let(:doc) do
    DesignDoc.create!(owner_user: owner, title: "Live collaboration", markdown: "Alpha beta", visibility: "private").tap do |design_doc|
      version = design_doc.versions.create!(markdown: design_doc.markdown, version_number: 1, actor_kind: "user", actor_user: owner)
      design_doc.update!(current_version: version)
      design_doc.collaborators.create!(user: collaborator, role: "editor", added_by_user: owner)
    end
  end

  before { allow(DesignDocs::CommentBroadcaster).to receive(:call) }

  it "broadcasts a normal suggestion after its transaction commits" do
    transaction_depth = ActiveRecord::Base.connection.open_transactions
    expect(DesignDocs::CommentBroadcaster).to receive(:call) do |design_doc:, changed:|
      expect(design_doc).to eq(doc)
      expect(changed).to eq([ "suggestions" ])
      expect(ActiveRecord::Base.connection.open_transactions).to eq(transaction_depth)
    end

    described_class.call(
      design_doc: doc,
      user: collaborator,
      attributes: { start_offset: 6, end_offset: 10, original_markdown: "beta", proposed_markdown: "gamma" }
    )
  end

  it "broadcasts both creation and the early-return update branches for autosaves" do
    attributes = {
      autosave: true,
      start_offset: 0,
      end_offset: 10,
      original_markdown: "Alpha beta",
      proposed_markdown: "First draft"
    }

    first = described_class.call(design_doc: doc, user: collaborator, attributes: attributes)
    second = described_class.call(design_doc: doc.reload, user: collaborator, attributes: attributes.merge(proposed_markdown: "Second draft"))

    expect(second.suggestion.id).to eq(first.suggestion.id)
    expect(second.suggestion.proposed_markdown).to eq("Second draft")
    expect(DesignDocs::CommentBroadcaster).to have_received(:call)
      .with(design_doc: doc, changed: [ "suggestions" ]).twice
  end
end
