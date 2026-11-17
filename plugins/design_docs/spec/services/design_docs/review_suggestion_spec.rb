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

  [ [ "bravo extended", 10 ], [ "b", -3 ] ].each do |replacement, offset_delta|
    it "refreshes a later non-overlapping anchor when accepted text changes length by #{offset_delta}" do
      accepted = DesignDocs::CreateSuggestion.call(
        design_doc: doc,
        user: collaborator,
        attributes: { start_offset: 6, end_offset: 10, original_markdown: "beta", proposed_markdown: replacement }
      ).suggestion
      later = DesignDocs::CreateSuggestion.call(
        design_doc: doc.reload,
        user: collaborator,
        attributes: { start_offset: 17, end_offset: 22, original_markdown: "delta", proposed_markdown: "DELTA" }
      ).suggestion

      described_class.accept(suggestion: accepted, user: owner)

      expect(later.anchor.reload).to have_attributes(
        status: "active",
        last_known_start_offset: 17 + offset_delta,
        last_known_end_offset: 22 + offset_delta
      )
      expect(DesignDocs::AnchorMarkers.strip(doc.reload.markdown)[later.anchor.last_known_start_offset...later.anchor.last_known_end_offset]).to eq("delta")
    end
  end

  it "marks an unrelated anchor stale with a reason when a direct edit removed its marker" do
    reviewed = DesignDocs::CreateSuggestion.call(
      design_doc: doc,
      user: collaborator,
      attributes: { start_offset: 6, end_offset: 10, original_markdown: "beta", proposed_markdown: "bravo" }
    ).suggestion
    marker_lost = DesignDocs::CreateSuggestion.call(
      design_doc: doc.reload,
      user: collaborator,
      attributes: { start_offset: 17, end_offset: 22, original_markdown: "delta", proposed_markdown: "DELTA" }
    ).suggestion
    doc.update!(markdown: DesignDocs::AnchorMarkers.remove(
      markdown: doc.markdown,
      marker_id: marker_lost.anchor.marker_id,
      anchor_kind: marker_lost.anchor.anchor_kind
    ))

    result = described_class.accept(suggestion: reviewed, user: owner)

    expect(marker_lost.reload).to have_attributes(state: "stale", conflict_reason: "Anchor marker is missing.")
    expect(marker_lost.anchor.reload).to have_attributes(status: "stale", stale_as_of_version: result.version)
  end

  it "keeps markers only for pending suggestions after accepting one suggestion" do
    accepted = DesignDocs::CreateSuggestion.call(
      design_doc: doc,
      user: collaborator,
      attributes: { start_offset: 6, end_offset: 10, original_markdown: "beta", proposed_markdown: "bravo" }
    ).suggestion
    pending = DesignDocs::CreateSuggestion.call(
      design_doc: doc.reload,
      user: collaborator,
      attributes: { start_offset: 17, end_offset: 22, original_markdown: "delta", proposed_markdown: "DELTA" }
    ).suggestion

    described_class.accept(suggestion: accepted, user: owner)

    doc.reload.suggestions.where.not(state: "pending").includes(:anchor).each do |suggestion|
      expect(doc.markdown).not_to include(suggestion.anchor.marker_id)
    end
    expect(doc.markdown).to include(pending.anchor.marker_id)
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

  it "repairs duplicate marker ids by staling their pending suggestion" do
    suggestion = DesignDocs::CreateSuggestion.call(
      design_doc: doc,
      user: collaborator,
      attributes: { start_offset: 6, end_offset: 10, original_markdown: "beta", proposed_markdown: "beta2" },
      actor_kind: "user"
    ).suggestion
    marker = DesignDocs::AnchorMarkers.range_start_marker(suggestion.anchor.marker_id)
    doc.update!(markdown: doc.markdown + marker)

    expect { DesignDocs::NormalizeAnchorMarkers.call(design_doc: doc) }.not_to raise_error
    expect(suggestion.reload).to have_attributes(state: "stale", conflict_reason: "Anchor marker is duplicated.")
    expect(doc.reload.markdown).not_to include(suggestion.anchor.marker_id)
  end

  it "removes an orphan range marker without raising" do
    doc.update!(markdown: doc.markdown + DesignDocs::AnchorMarkers.range_start_marker("orphan"))

    expect { DesignDocs::NormalizeAnchorMarkers.call(design_doc: doc) }.not_to raise_error
    expect(doc.reload.markdown).not_to include("orphan")
  end

  it "stales active pending suggestions whose ranges overlap" do
    first = DesignDocs::CreateSuggestion.call(
      design_doc: doc,
      user: collaborator,
      attributes: { start_offset: 6, end_offset: 10, original_markdown: "beta", proposed_markdown: "beta2" },
      actor_kind: "user"
    ).suggestion
    second_anchor = doc.anchors.create!(
      marker_id: "manual-overlap",
      anchor_key: "manual-overlap",
      anchor_kind: "range",
      design_doc_version: doc.current_version,
      start_offset: 8,
      end_offset: 16,
      last_known_start_offset: 8,
      last_known_end_offset: 16,
      selected_markdown: "ta gamma",
      selected_text: "ta gamma",
      status: "active"
    )
    inserted = DesignDocs::AnchorMarkers.insert(
      markdown: doc.markdown,
      marker_id: second_anchor.marker_id,
      start_offset: 8,
      end_offset: 16,
      anchor_kind: "range"
    )
    doc.update!(markdown: inserted.markdown)
    doc.suggestions.create!(
      anchor: second_anchor,
      suggested_by_kind: "user",
      suggested_by_user: collaborator,
      original_markdown: "ta gamma",
      suggested_markdown: "replacement",
      proposed_markdown: "replacement"
    )

    second = DesignDocSuggestion.last
    expect { DesignDocs::NormalizeAnchorMarkers.call(design_doc: doc) }.not_to raise_error
    expect(first.reload.state).to eq("stale")
    expect(first.conflict_reason).to include("##{second.id}")
    expect(second.reload.state).to eq("stale")
    expect(second.conflict_reason).to include("##{first.id}")
    expect(doc.reload.markdown).not_to include(first.anchor.marker_id, second.anchor.marker_id)
  end

  it "accepts a valid suggestion while repairing two unrelated nested pending ranges" do
    first = DesignDocs::CreateSuggestion.call(
      design_doc: doc, user: collaborator,
      attributes: { start_offset: 6, end_offset: 10, original_markdown: "beta", proposed_markdown: "bravo" }
    ).suggestion
    second = DesignDocs::CreateSuggestion.call(
      design_doc: doc.reload, user: collaborator,
      attributes: { start_offset: 11, end_offset: 16, original_markdown: "gamma", proposed_markdown: "gimel" }
    ).suggestion
    third = DesignDocs::CreateSuggestion.call(
      design_doc: doc.reload, user: collaborator,
      attributes: { start_offset: 17, end_offset: 22, original_markdown: "delta", proposed_markdown: "DELTA" }
    ).suggestion
    markers = DesignDocs::AnchorMarkers
    doc.update!(markdown: "Alpha #{markers.range_start_marker(first.anchor.marker_id)}#{markers.range_start_marker(second.anchor.marker_id)}beta gamma#{markers.range_end_marker(second.anchor.marker_id)}#{markers.range_end_marker(first.anchor.marker_id)} #{markers.range_start_marker(third.anchor.marker_id)}delta#{markers.range_end_marker(third.anchor.marker_id)}")

    result = described_class.accept(suggestion: third, user: owner)

    expect(result.applied).to be(true)
    expect(first.reload.state).to eq("stale")
    expect(second.reload.state).to eq("stale")
    expect(first.conflict_reason).to include("##{second.id}")
    expect(second.conflict_reason).to include("##{first.id}")
    expect(DesignDocs::AnchorMarkers.marker_counts(doc.reload.markdown)).to be_empty
    expect(DesignDocs::AnchorMarkers.strip(doc.markdown)).to eq("Alpha beta gamma DELTA")
  end

  it "accepts a valid suggestion despite a duplicated marker on an unrelated suggestion" do
    broken = DesignDocs::CreateSuggestion.call(
      design_doc: doc, user: collaborator,
      attributes: { start_offset: 6, end_offset: 10, original_markdown: "beta", proposed_markdown: "bravo" }
    ).suggestion
    valid = DesignDocs::CreateSuggestion.call(
      design_doc: doc.reload, user: collaborator,
      attributes: { start_offset: 17, end_offset: 22, original_markdown: "delta", proposed_markdown: "DELTA" }
    ).suggestion
    doc.update!(markdown: doc.markdown + DesignDocs::AnchorMarkers.range_start_marker(broken.anchor.marker_id))

    expect(described_class.accept(suggestion: valid, user: owner).applied).to be(true)
    expect(broken.reload.state).to eq("stale")
    expect(doc.reload.markdown).not_to include(broken.anchor.marker_id)
  end

  it "rejects a valid suggestion despite an orphan marker on an unrelated suggestion" do
    broken = DesignDocs::CreateSuggestion.call(
      design_doc: doc, user: collaborator,
      attributes: { start_offset: 6, end_offset: 10, original_markdown: "beta", proposed_markdown: "bravo" }
    ).suggestion
    valid = DesignDocs::CreateSuggestion.call(
      design_doc: doc.reload, user: collaborator,
      attributes: { start_offset: 17, end_offset: 22, original_markdown: "delta", proposed_markdown: "DELTA" }
    ).suggestion
    orphaned = doc.markdown.sub(DesignDocs::AnchorMarkers.range_end_marker(broken.anchor.marker_id), "")
    doc.update!(markdown: orphaned)

    expect(described_class.reject(suggestion: valid, user: owner).applied).to be(false)
    expect(valid.reload.state).to eq("rejected")
    expect(broken.reload.state).to eq("stale")
    expect(doc.reload.markdown).not_to include(broken.anchor.marker_id)
  end
end
