require "rails_helper"
require Rails.root.join("plugins/design_docs/db/migrate/20260903120100_add_render_mode_to_design_doc_suggestions")

RSpec.describe AddRenderModeToDesignDocSuggestions, :ci_only do
  let(:owner) { Factories.user(email_address: "owner@example.com") }

  it "backfills legacy single-line Markdown block suggestions as block render mode" do
    doc = create_design_doc(markdown: "# Old Title\n\n- Old item\n\nBody")
    heading = legacy_suggestion(doc, original_markdown: "# Old Title", proposed_markdown: "# New Title")
    list_item = legacy_suggestion(doc, original_markdown: "- Old item", proposed_markdown: "- New item")
    phrase = legacy_suggestion(doc, original_markdown: "Body", proposed_markdown: "Updated body")

    described_class.new.up

    expect(heading.reload.render_mode).to eq("block")
    expect(list_item.reload.render_mode).to eq("block")
    expect(phrase.reload.render_mode).to eq("inline")
  end

  private

  def create_design_doc(markdown:)
    doc = DesignDoc.create!(
      owner_user: owner,
      title: "Checkout design",
      markdown: markdown,
      visibility: "private"
    )
    version = doc.versions.create!(
      markdown: doc.markdown,
      version_number: 1,
      actor_kind: "user",
      actor_user: owner
    )
    doc.update!(current_version: version)
    doc
  end

  def legacy_suggestion(doc, original_markdown:, proposed_markdown:)
    anchor = doc.anchors.create!(
      marker_id: SecureRandom.uuid,
      anchor_key: SecureRandom.uuid,
      anchor_kind: "range",
      design_doc_version: doc.current_version,
      start_offset: doc.markdown.index(original_markdown),
      end_offset: doc.markdown.index(original_markdown) + original_markdown.length,
      last_known_start_offset: doc.markdown.index(original_markdown),
      last_known_end_offset: doc.markdown.index(original_markdown) + original_markdown.length,
      selected_markdown: original_markdown,
      selected_text: original_markdown,
      status: "active"
    )
    thread = doc.threads.create!(anchor: anchor, opened_by_user: owner)
    doc.suggestions.create!(
      anchor: anchor,
      thread: thread,
      base_version: doc.current_version,
      suggested_by_kind: "user",
      suggested_by_user: owner,
      original_markdown: original_markdown,
      suggested_markdown: proposed_markdown,
      proposed_markdown: proposed_markdown,
      change_type: "replace",
      render_mode: "inline"
    )
  end
end
