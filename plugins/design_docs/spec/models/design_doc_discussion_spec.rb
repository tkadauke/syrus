require "rails_helper"

RSpec.describe "design doc discussions", type: :model do
  let(:owner) { Factories.user }
  let(:doc) { DesignDocs::DesignDoc.create!(owner_user: owner, title: "Discussion", markdown: "Hello world") }

  it "anchors comments and suggestions to a single design doc range" do
    version = doc.versions.create!(markdown: doc.markdown, version_number: 1, actor_kind: "user", actor_user: owner)
    anchor = doc.anchors.create!(design_doc_version: version, start_offset: 0, end_offset: 5, selected_markdown: "Hello")
    thread = doc.threads.create!(anchor: anchor, opened_by_user: owner)
    comment = thread.comments.create!(author_kind: "user", author_user: owner, body: " tighten this ")
    suggestion = doc.suggestions.create!(
      anchor: anchor,
      thread: thread,
      suggested_by_kind: "agent",
      original_markdown: "Hello",
      suggested_markdown: "Hi",
      change_summary: "Shorten greeting"
    )

    expect(anchor.anchor_key).to be_present
    expect(anchor.hidden_marker).to include(anchor.anchor_key)
    expect(comment.body).to eq("tighten this")
    expect(suggestion.state).to eq("pending")
  end

  it "rejects anchors, threads, and suggestions that cross design doc boundaries" do
    other_doc = DesignDocs::DesignDoc.create!(owner_user: owner, title: "Other", markdown: "Other")
    other_anchor = other_doc.anchors.create!(start_offset: 0, end_offset: 1)
    anchor = doc.anchors.create!(start_offset: 0, end_offset: 1)
    thread = doc.threads.create!(anchor: anchor, opened_by_user: owner)

    cross_thread = doc.threads.build(anchor: other_anchor)
    cross_suggestion = doc.suggestions.build(
      anchor: anchor,
      thread: other_doc.threads.create!(anchor: other_anchor, opened_by_user: owner),
      suggested_by_kind: "agent",
      original_markdown: "a",
      suggested_markdown: "b"
    )

    expect(cross_thread).not_to be_valid
    expect(cross_thread.errors[:anchor]).to include("must belong to the same design doc")
    expect(cross_suggestion).not_to be_valid
    expect(cross_suggestion.errors[:thread]).to include("must belong to the same design doc")
    expect(thread.state).to eq("open")
  end

  it "keeps pending suggestions and open threads unreviewed and unresolved" do
    anchor = doc.anchors.create!(start_offset: 0, end_offset: 1)
    thread = doc.threads.build(anchor: anchor, state: "open", resolved_at: Time.current, resolved_by_user: owner)
    suggestion = doc.suggestions.build(
      anchor: anchor,
      suggested_by_kind: "user",
      suggested_by_user: owner,
      state: "pending",
      original_markdown: "a",
      suggested_markdown: "b",
      reviewed_at: Time.current,
      reviewed_by_user: owner
    )

    expect(thread).not_to be_valid
    expect(thread.errors[:resolved_at]).to be_present
    expect(suggestion).not_to be_valid
    expect(suggestion.errors[:reviewed_at]).to be_present
  end

  it "inserts later anchors at rendered markdown offsets after existing hidden markers" do
    doc.update!(markdown: "Alpha beta gamma")
    doc.versions.create!(markdown: doc.markdown, version_number: 1, actor_kind: "user", actor_user: owner)
    first = DesignDocs::CreateAnchor.call(
      design_doc: doc,
      user: owner,
      attributes: { start_offset: 6, end_offset: 10, selected_markdown: "beta" }
    ).anchor
    second = DesignDocs::CreateAnchor.call(
      design_doc: doc,
      user: owner,
      attributes: { start_offset: 11, end_offset: 16, selected_markdown: "gamma" }
    ).anchor

    expect(DesignDocs::AnchorMarkers.strip(doc.reload.markdown)).to eq("Alpha beta gamma")
    expect(doc.markdown).to include("<!-- syrus:range-start id=\"#{first.marker_id}\" -->beta<!-- syrus:range-end id=\"#{first.marker_id}\" -->")
    expect(doc.markdown).to include("<!-- syrus:range-start id=\"#{second.marker_id}\" -->gamma<!-- syrus:range-end id=\"#{second.marker_id}\" -->")
    expect(second).to have_attributes(start_offset: 11, end_offset: 16, selected_text: "gamma")
  end

  it "reanchors a mismatched submitted range when selected text is unique" do
    doc.update!(markdown: "# Backlog\n\n- Risks drift before the target.\n\n## Open Questions\n\n- Should backlogged Jobs be owned, claimed, both, or neither by default?")
    doc.versions.create!(markdown: doc.markdown, version_number: 1, actor_kind: "user", actor_user: owner)
    selected = "Should backlogged Jobs be owned, claimed, both, or neither by default?"

    result = DesignDocs::CreateAnchor.call(
      design_doc: doc,
      user: owner,
      attributes: {
        start_offset: doc.markdown.index("Risks"),
        end_offset: doc.markdown.index("Risks") + selected.length,
        selected_text: selected
      }
    )

    anchor = result.anchor
    expect(anchor.selected_text).to eq(selected)
    expect(DesignDocs::AnchorMarkers.locate(markdown: doc.reload.markdown, marker_id: anchor.marker_id, anchor_kind: "range").selected_markdown).to eq(selected)
  end

  it "rejects ambiguous mismatched selected text without inserting markers" do
    doc.update!(markdown: "Alpha beta\n\nBeta elsewhere\n\nAlpha beta")
    doc.versions.create!(markdown: doc.markdown, version_number: 1, actor_kind: "user", actor_user: owner)
    original_markdown = doc.markdown

    expect {
      DesignDocs::CreateAnchor.call(
        design_doc: doc,
        user: owner,
        attributes: { start_offset: 0, end_offset: 5, selected_text: "Alpha beta" }
      )
    }.to raise_error(ActiveRecord::RecordInvalid, /appears multiple times/)

    expect(doc.reload.markdown).to eq(original_markdown)
  end

  it "validates submitted offsets against marker-stripped markdown" do
    doc.update!(markdown: "Alpha beta gamma")
    doc.versions.create!(markdown: doc.markdown, version_number: 1, actor_kind: "user", actor_user: owner)
    first = DesignDocs::CreateAnchor.call(
      design_doc: doc,
      user: owner,
      attributes: { start_offset: 6, end_offset: 10, selected_text: "beta" }
    ).anchor

    second = DesignDocs::CreateAnchor.call(
      design_doc: doc.reload,
      user: owner,
      attributes: { start_offset: 11, end_offset: 16, selected_text: "gamma" }
    ).anchor

    expect(doc.reload.markdown).to include("<!-- syrus:range-start id=\"#{first.marker_id}\" -->beta<!-- syrus:range-end id=\"#{first.marker_id}\" -->")
    expect(doc.markdown).to include("<!-- syrus:range-start id=\"#{second.marker_id}\" -->gamma<!-- syrus:range-end id=\"#{second.marker_id}\" -->")
  end
end
