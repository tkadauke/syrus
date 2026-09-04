class AddStaleAsOfVersionToDesignDocAnchors < ActiveRecord::Migration[8.1]
  def change
    unless column_exists?(:design_doc_anchors, :stale_as_of_version_id)
      add_column :design_doc_anchors, :stale_as_of_version_id, :integer
    end

    unless index_exists?(:design_doc_anchors, :stale_as_of_version_id)
      add_index :design_doc_anchors, :stale_as_of_version_id
    end

    unless foreign_key_exists?(:design_doc_anchors, :design_doc_versions, column: :stale_as_of_version_id)
      add_foreign_key :design_doc_anchors, :design_doc_versions, column: :stale_as_of_version_id
    end
  end
end
