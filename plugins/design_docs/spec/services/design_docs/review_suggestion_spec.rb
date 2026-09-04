require "rails_helper"

RSpec.describe DesignDocs::ReviewSuggestion do
  let(:owner) { Factories.user(email_address: "owner@example.com") }
  let(:collaborator) { Factories.user(email_address: "collaborator@example.com") }
  let(:doc) do
    doc = DesignDoc.create!(owner_user: owner, title: "Directory RFC", markdown: "Alpha beta gamma delta", visibility: "private")
    doc.collaborators.create!(user: collaborator, role: "editor", added_by_user: owner)
    version = doc.versions.create!(markdown: doc.markdown, version_number: 1, actor_kind: "user", actor_user: owner)
    doc.update!(current_version: version)
    doc
  end

  # Reproduces the DOC-20 production sequence: a comment anchor exists, then a
  # later full-document suggestion is accepted and its replaced range spans
  # every marker in the document, not just its own.
  it "marks an overwritten comment anchor stale and cascades to its pending suggestions, while re-projecting an anchor whose exact text survives" do
    beta_comment = DesignDocs::CreateComment.call(
      design_doc: doc,
      user: collaborator,
      attributes: { body: "Needs more evidence", start_offset: 6, end_offset: 10, selected_markdown: "beta" },
      actor_kind: "user"
    )
    gamma_comment = DesignDocs::CreateComment.call(
      design_doc: doc.reload,
      user: collaborator,
      attributes: { body: "Keep this term", start_offset: 11, end_offset: 16, selected_markdown: "gamma" },
      actor_kind: "user"
    )
    beta_anchor = beta_comment.anchor
    gamma_anchor = gamma_comment.anchor
    pending_reply_suggestion = doc.reload.suggestions.create!(
      anchor: beta_anchor,
      thread: beta_comment.thread,
      suggested_by_kind: "user",
      suggested_by_user: collaborator,
      original_markdown: "beta",
      suggested_markdown: "beta2"
    )

    full_document_suggestion = DesignDocs::CreateSuggestion.call(
      design_doc: doc.reload,
      user: collaborator,
      attributes: {
        start_offset: 0,
        end_offset: DesignDocs::AnchorMarkers.strip(doc.markdown).length,
        original_markdown: DesignDocs::AnchorMarkers.strip(doc.markdown),
        proposed_markdown: "Zeta gamma omega",
        change_summary: "Full rewrite"
      },
      actor_kind: "user"
    ).suggestion

    result = described_class.accept(suggestion: full_document_suggestion, user: owner)

    expect(result.applied).to be(true)
    expect(DesignDocs::AnchorMarkers.strip(doc.reload.markdown)).to eq("Zeta gamma omega")

    expect(beta_anchor.reload.status).to eq("stale")
    expect(beta_anchor.stale_as_of_version).to eq(result.version)
    expect(pending_reply_suggestion.reload.state).to eq("stale")
    expect(pending_reply_suggestion.conflict_reason).to include("suggestion ##{full_document_suggestion.id}")

    expect(gamma_anchor.reload.status).to eq("active")
    expect(DesignDocs::AnchorMarkers.strip(doc.markdown)[gamma_anchor.last_known_start_offset...gamma_anchor.last_known_end_offset]).to eq("gamma")
    expect(doc.markdown).to include(DesignDocs::AnchorMarkers.range_start_marker(gamma_anchor.marker_id))
  end

  it "reports anchors as active only within their version window" do
    beta_comment = DesignDocs::CreateComment.call(
      design_doc: doc,
      user: collaborator,
      attributes: { body: "Needs more evidence", start_offset: 6, end_offset: 10, selected_markdown: "beta" },
      actor_kind: "user"
    )
    beta_anchor = beta_comment.anchor
    birth_version_number = beta_anchor.design_doc_version.version_number

    full_document_suggestion = DesignDocs::CreateSuggestion.call(
      design_doc: doc.reload,
      user: collaborator,
      attributes: {
        start_offset: 0,
        end_offset: DesignDocs::AnchorMarkers.strip(doc.markdown).length,
        original_markdown: DesignDocs::AnchorMarkers.strip(doc.markdown),
        proposed_markdown: "Nothing familiar here"
      },
      actor_kind: "user"
    ).suggestion
    result = described_class.accept(suggestion: full_document_suggestion, user: owner)
    stale_version_number = beta_anchor.reload.stale_as_of_version.version_number

    expect(DesignDocAnchor.active_as_of(birth_version_number)).not_to include(beta_anchor)
    expect(DesignDocAnchor.active_as_of(birth_version_number + 1)).to include(beta_anchor)
    expect(DesignDocAnchor.active_as_of(stale_version_number - 1)).to include(beta_anchor)
    expect(DesignDocAnchor.active_as_of(stale_version_number)).not_to include(beta_anchor)
    expect(result.applied).to be(true)
  end
end
