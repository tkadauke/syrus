class AddInlineReviewStateToDesignDocs < ActiveRecord::Migration[8.1]
  def change
    add_column :design_doc_anchors, :marker_id, :string unless column_exists?(:design_doc_anchors, :marker_id)
    unless column_exists?(:design_doc_anchors, :anchor_kind)
      add_column :design_doc_anchors, :anchor_kind, :string, null: false, default: "range"
    end
    unless column_exists?(:design_doc_anchors, :status)
      add_column :design_doc_anchors, :status, :string, null: false, default: "active"
    end
    add_column :design_doc_anchors, :selected_text, :text unless column_exists?(:design_doc_anchors, :selected_text)
    add_column :design_doc_anchors, :prefix_context, :text unless column_exists?(:design_doc_anchors, :prefix_context)
    add_column :design_doc_anchors, :suffix_context, :text unless column_exists?(:design_doc_anchors, :suffix_context)
    unless column_exists?(:design_doc_anchors, :last_known_start_offset)
      add_column :design_doc_anchors, :last_known_start_offset, :integer
    end
    unless column_exists?(:design_doc_anchors, :last_known_end_offset)
      add_column :design_doc_anchors, :last_known_end_offset, :integer
    end

    reversible do |dir|
      dir.up do
        execute <<~SQL.squish
          UPDATE design_doc_anchors
          SET marker_id = anchor_key,
              selected_text = selected_markdown,
              last_known_start_offset = start_offset,
              last_known_end_offset = end_offset
          WHERE marker_id IS NULL
        SQL
      end
    end
    change_column_null :design_doc_anchors, :marker_id, false

    unless index_exists?(:design_doc_anchors, [ :design_doc_id, :marker_id ], name: "index_design_doc_anchors_on_doc_and_marker_id")
      add_index :design_doc_anchors, [ :design_doc_id, :marker_id ],
        unique: true,
        name: "index_design_doc_anchors_on_doc_and_marker_id"
    end

    add_column :design_doc_suggestions, :proposed_markdown, :text unless column_exists?(:design_doc_suggestions, :proposed_markdown)
    unless column_exists?(:design_doc_suggestions, :change_type)
      add_column :design_doc_suggestions, :change_type, :string, null: false, default: "replace"
    end
    add_column :design_doc_suggestions, :base_version_id, :integer unless column_exists?(:design_doc_suggestions, :base_version_id)
    add_column :design_doc_suggestions, :provenance, :json unless column_exists?(:design_doc_suggestions, :provenance)
    add_column :design_doc_suggestions, :conflict_reason, :text unless column_exists?(:design_doc_suggestions, :conflict_reason)

    reversible do |dir|
      dir.up do
        execute <<~SQL.squish
          UPDATE design_doc_suggestions
          SET proposed_markdown = suggested_markdown
          WHERE proposed_markdown IS NULL
        SQL
      end
    end
    change_column_null :design_doc_suggestions, :proposed_markdown, false

    add_index :design_doc_suggestions, :base_version_id unless index_exists?(:design_doc_suggestions, :base_version_id)
    unless foreign_key_exists?(:design_doc_suggestions, :design_doc_versions, column: :base_version_id)
      add_foreign_key :design_doc_suggestions, :design_doc_versions, column: :base_version_id
    end
  end
end
