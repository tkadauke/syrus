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

  it "atomically refuses to review a suggestion when canonical markdown is marker-only" do
    suggestion = DesignDocs::CreateSuggestion.call(
      design_doc: doc,
      user: collaborator,
      attributes: { start_offset: 6, end_offset: 10, original_markdown: "beta", proposed_markdown: "bravo" }
    ).suggestion
    marker_only = DesignDocs::AnchorMarkers.range_start_marker(suggestion.anchor.marker_id) +
      DesignDocs::AnchorMarkers.range_end_marker(suggestion.anchor.marker_id)
    doc.update_column(:markdown, marker_only)
    before = {
      markdown: doc.reload.markdown,
      current_version_id: doc.current_version_id,
      versions: doc.versions.count,
      suggestion: suggestion.reload.attributes,
      anchor: suggestion.anchor.reload.attributes
    }

    expect {
      described_class.accept(suggestion: suggestion, user: owner)
    }.to raise_error(described_class::BlankCanonicalBody, /Restore nonblank content/)

    expect(doc.reload.markdown).to eq(before[:markdown])
    expect(doc.current_version_id).to eq(before[:current_version_id])
    expect(doc.versions.count).to eq(before[:versions])
    expect(suggestion.reload.attributes).to eq(before[:suggestion])
    expect(suggestion.anchor.reload.attributes).to eq(before[:anchor])
  end

  it "atomically refuses a suggestion that would delete the entire visible body" do
    suggestion = DesignDocs::CreateSuggestion.call(
      design_doc: doc,
      user: collaborator,
      attributes: {
        start_offset: 0,
        end_offset: DesignDocs::AnchorMarkers.strip(doc.markdown).length,
        original_markdown: DesignDocs::AnchorMarkers.strip(doc.markdown),
        proposed_markdown: "replacement"
      }
    ).suggestion
    suggestion.update_columns(suggested_markdown: "", proposed_markdown: "")
    before = {
      markdown: doc.reload.markdown,
      current_version_id: doc.current_version_id,
      versions: doc.versions.count,
      suggestion: suggestion.reload.attributes,
      anchor: suggestion.anchor.reload.attributes
    }

    expect {
      described_class.accept(suggestion: suggestion, user: owner)
    }.to raise_error(described_class::BlankCanonicalBody, /would leave.*blank/)

    expect(doc.reload.markdown).to eq(before[:markdown])
    expect(doc.current_version_id).to eq(before[:current_version_id])
    expect(doc.versions.count).to eq(before[:versions])
    expect(suggestion.reload.attributes).to eq(before[:suggestion])
    expect(suggestion.anchor.reload.attributes).to eq(before[:anchor])
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
    pending_reply_suggestion = doc.reload.suggestions.create!(
      anchor: beta_anchor,
      thread: beta_comment.thread,
      suggested_by_kind: "user",
      suggested_by_user: collaborator,
      original_markdown: "beta",
      suggested_markdown: "beta2"
    )

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
    expect(doc.markdown).not_to include(full_document_suggestion.anchor.marker_id)
    expect(full_document_suggestion.anchor.reload.status).to eq("stale")
  end

  # Reproduces a comment anchor and a pending suggestion whose ranges
  # partially overlap (neither fully nests inside the other): accepting the
  # suggestion's `AnchorMarkers.replace_range` deletes only the side of the
  # comment anchor's start/end marker pair that falls inside the accepted
  # range, leaving the other side dangling. Without cleanup that leftover
  # fragment gets duplicated by re-projection and blows up
  # `NormalizeAnchorMarkers.assert_marker_pairs!`.
  it "safely reprojects a comment anchor whose range partially overlaps an accepted suggestion when its exact text still exists afterward" do
    comment = DesignDocs::CreateComment.call(
      design_doc: doc,
      user: collaborator,
      attributes: { body: "Keep an eye on this phrase", start_offset: 6, end_offset: 16, selected_markdown: "beta gamma" },
      actor_kind: "user"
    )
    comment_anchor = comment.anchor

    suggestion = DesignDocs::CreateSuggestion.call(
      design_doc: doc.reload,
      user: collaborator,
      attributes: {
        start_offset: 0,
        end_offset: 10,
        original_markdown: "Alpha beta",
        proposed_markdown: "Omega beta",
        change_summary: "Reword the opening"
      },
      actor_kind: "user"
    ).suggestion

    result = nil
    expect {
      result = described_class.accept(suggestion: suggestion, user: owner)
    }.not_to raise_error

    expect(result.applied).to be(true)
    expect(suggestion.reload.state).to eq("accepted")
    expect(DesignDocs::AnchorMarkers.strip(doc.reload.markdown)).to eq("Omega beta gamma delta")
    expect { DesignDocs::NormalizeAnchorMarkers.call(design_doc: doc) }.not_to raise_error

    expect(comment_anchor.reload.status).to eq("active")
    reprojected_start = comment_anchor.last_known_start_offset
    reprojected_end = comment_anchor.last_known_end_offset
    expect(DesignDocs::AnchorMarkers.strip(doc.markdown)[reprojected_start...reprojected_end]).to eq("beta gamma")
  end

  it "marks a partially overlapping comment anchor stale and cascades its pending replies when accepting a suggestion destroys its exact text" do
    comment = DesignDocs::CreateComment.call(
      design_doc: doc,
      user: collaborator,
      attributes: { body: "Keep an eye on this phrase", start_offset: 6, end_offset: 16, selected_markdown: "beta gamma" },
      actor_kind: "user"
    )
    comment_anchor = comment.anchor
    pending_reply = doc.reload.suggestions.create!(
      anchor: comment_anchor,
      thread: comment.thread,
      suggested_by_kind: "user",
      suggested_by_user: collaborator,
      original_markdown: "beta gamma",
      suggested_markdown: "beta gamma!"
    )

    # Built directly rather than through DesignDocs::CreateSuggestion, since
    # that service's own `validate_pending_overlap!` correctly refuses to let
    # an operator create a suggestion overlapping the comment's own pending
    # reply through the UI. That guard is a separate feature; here we only
    # want to exercise DesignDocs::ReviewSuggestion.accept's reconciliation
    # once such a state exists.
    doc.reload
    suggestion_anchor = doc.anchors.create!(
      marker_id: "manual-overlap-accept",
      anchor_key: "manual-overlap-accept",
      anchor_kind: "range",
      design_doc_version: doc.current_version,
      start_offset: 0,
      end_offset: 10,
      last_known_start_offset: 0,
      last_known_end_offset: 10,
      selected_markdown: "Alpha beta",
      selected_text: "Alpha beta",
      status: "active"
    )
    inserted = DesignDocs::AnchorMarkers.insert(
      markdown: doc.markdown,
      marker_id: suggestion_anchor.marker_id,
      start_offset: 0,
      end_offset: 10,
      anchor_kind: "range"
    )
    doc.update!(markdown: inserted.markdown)
    suggestion = doc.suggestions.create!(
      anchor: suggestion_anchor,
      suggested_by_kind: "user",
      suggested_by_user: collaborator,
      original_markdown: "Alpha beta",
      suggested_markdown: "Zzz zzzzz",
      proposed_markdown: "Zzz zzzzz",
      change_summary: "Reword the opening"
    )

    result = nil
    expect {
      result = described_class.accept(suggestion: suggestion, user: owner)
    }.not_to raise_error

    expect(result.applied).to be(true)
    expect(suggestion.reload.state).to eq("accepted")
    expect(DesignDocs::AnchorMarkers.strip(doc.reload.markdown)).to eq("Zzz zzzzz gamma delta")
    expect { DesignDocs::NormalizeAnchorMarkers.call(design_doc: doc) }.not_to raise_error

    expect(comment_anchor.reload.status).to eq("stale")
    expect(doc.markdown).not_to include(comment_anchor.marker_id)
    expect(pending_reply.reload.state).to eq("stale")
    expect(pending_reply.conflict_reason).to include("suggestion ##{suggestion.id}")
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

  it "stamps stale_as_of_version on the anchor when the suggestion's own text has drifted, not just when an unrelated overwrite reconciles it" do
    suggestion = DesignDocs::CreateSuggestion.call(
      design_doc: doc,
      user: collaborator,
      attributes: { start_offset: 6, end_offset: 10, original_markdown: "beta", proposed_markdown: "beta2" },
      actor_kind: "user"
    ).suggestion
    anchor = suggestion.anchor
    birth_version_number = anchor.design_doc_version.version_number

    # An intervening checkpointed version elapses before anyone reviews the
    # suggestion, then the live markdown drifts (e.g. an owner autosave)
    # without a matching version -- design_doc.current_version stays pinned
    # to the last real checkpoint, which is the best available "as of"
    # marker for when the suggestion's assumptions stopped holding.
    doc.reload
    intervening_version = doc.versions.create!(markdown: doc.markdown, version_number: doc.versions.maximum(:version_number) + 1, actor_kind: "user", actor_user: owner)
    doc.update!(current_version: intervening_version)
    doc.update!(markdown: doc.markdown.sub("beta", "zeta"))

    result = described_class.accept(suggestion: suggestion, user: owner)

    expect(result.applied).to be(false)
    expect(suggestion.reload.state).to eq("stale")
    expect(anchor.reload.status).to eq("stale")
    expect(anchor.stale_as_of_version).to eq(result.version)

    expect(DesignDocAnchor.active_as_of(birth_version_number + 1)).to include(anchor)
    expect(DesignDocAnchor.active_as_of(intervening_version.version_number)).to include(anchor)
    expect(DesignDocAnchor.active_as_of(result.version.version_number)).not_to include(anchor)
  end

  it "removes rejected suggestion markers while keeping the reviewed suggestion historically inspectable" do
    suggestion = DesignDocs::CreateSuggestion.call(
      design_doc: doc,
      user: collaborator,
      attributes: { start_offset: 6, end_offset: 10, original_markdown: "beta", proposed_markdown: "beta2" },
      actor_kind: "user"
    ).suggestion
    marker_id = suggestion.anchor.marker_id
    marked_markdown = doc.reload.markdown

    result = described_class.reject(suggestion: suggestion, user: owner)

    expect(result.applied).to be(false)
    expect(result.version.markdown).to eq(DesignDocs::AnchorMarkers.strip(marked_markdown))
    expect(doc.reload.markdown).not_to include(marker_id)
    expect(suggestion.reload.state).to eq("rejected")
    expect(suggestion.anchor.reload).to have_attributes(status: "stale", stale_as_of_version: result.version)
  end

  it "accepts a valid suggestion while making colliding unrelated pending ranges stale" do
    first = create_manual_suggestion(start_offset: 0, end_offset: 10, marker_id: "collision-one")
    second = create_manual_suggestion(start_offset: 6, end_offset: 16, marker_id: "collision-two")
    valid = create_manual_suggestion(start_offset: 17, end_offset: 22, marker_id: "valid-third", proposed_markdown: "omega")

    result = described_class.accept(suggestion: valid, user: owner)

    expect(result.applied).to be(true)
    expect(valid.reload.state).to eq("accepted")
    expect([ first.reload.state, second.reload.state ]).to eq(%w[stale stale])
    expect(first.conflict_reason).to include("overlaps ##{second.id}")
    expect(second.conflict_reason).to include("overlaps ##{first.id}")
    expect(first.anchor.reload.status).to eq("stale")
    expect(second.anchor.reload.status).to eq("stale")
    expect(doc.reload.markdown).not_to match(/collision-one|collision-two|valid-third/)
    expect(DesignDocs::AnchorMarkers.strip(doc.markdown)).to eq("Alpha beta gamma omega")
  end

  it "repairs duplicate and orphan markers for unrelated suggestions while accepting another suggestion" do
    broken = create_manual_suggestion(start_offset: 11, end_offset: 16, marker_id: "duplicated-unrelated")
    valid = create_manual_suggestion(start_offset: 6, end_offset: 10, marker_id: "valid-review", proposed_markdown: "bravo")
    doc.update!(markdown: doc.markdown + DesignDocs::AnchorMarkers.range_start_marker(broken.anchor.marker_id) + DesignDocs::AnchorMarkers.range_start_marker("orphan"))

    expect { described_class.accept(suggestion: valid, user: owner) }.not_to raise_error

    expect(broken.reload.state).to eq("stale")
    expect(broken.conflict_reason).to eq("Anchor marker was duplicated.")
    expect(doc.reload.markdown).not_to match(/duplicated-unrelated|orphan|valid-review/)
  end

  it "repairs malformed markers for unrelated suggestions while rejecting another suggestion" do
    broken = create_manual_suggestion(start_offset: 11, end_offset: 16, marker_id: "orphaned-unrelated")
    valid = create_manual_suggestion(start_offset: 6, end_offset: 10, marker_id: "valid-reject")
    end_marker = DesignDocs::AnchorMarkers.range_end_marker(broken.anchor.marker_id)
    doc.update!(markdown: doc.markdown.sub(end_marker, ""))

    expect { described_class.reject(suggestion: valid, user: owner) }.not_to raise_error

    expect(valid.reload.state).to eq("rejected")
    expect(broken.reload.state).to eq("stale")
    expect(broken.conflict_reason).to eq("Anchor marker had an orphan range marker.")
    expect(doc.reload.markdown).not_to match(/orphaned-unrelated|valid-reject/)
  end

  def create_manual_suggestion(start_offset:, end_offset:, marker_id:, proposed_markdown: "replacement")
    visible = DesignDocs::AnchorMarkers.strip(doc.reload.markdown)
    selected = visible[start_offset...end_offset]
    anchor = doc.anchors.create!(
      marker_id: marker_id,
      anchor_key: marker_id,
      anchor_kind: "range",
      design_doc_version: doc.current_version,
      start_offset: start_offset,
      end_offset: end_offset,
      last_known_start_offset: start_offset,
      last_known_end_offset: end_offset,
      selected_markdown: selected,
      selected_text: selected,
      status: "active"
    )
    inserted = DesignDocs::AnchorMarkers.insert(
      markdown: doc.markdown,
      marker_id: marker_id,
      start_offset: start_offset,
      end_offset: end_offset,
      anchor_kind: "range"
    )
    doc.update!(markdown: inserted.markdown)
    doc.suggestions.create!(
      anchor: anchor,
      suggested_by_kind: "user",
      suggested_by_user: collaborator,
      original_markdown: selected,
      suggested_markdown: proposed_markdown,
      proposed_markdown: proposed_markdown
    )
  end
end
