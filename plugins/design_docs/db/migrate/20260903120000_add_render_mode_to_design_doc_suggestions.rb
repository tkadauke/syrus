class AddRenderModeToDesignDocSuggestions < ActiveRecord::Migration[8.1]
  def change
    unless column_exists?(:design_doc_suggestions, :render_mode)
      add_column :design_doc_suggestions, :render_mode, :string, null: false, default: "inline"
    end

    reversible do |dir|
      dir.up do
        newline_pattern = connection.quote("%\n%")
        execute <<~SQL.squish
          UPDATE design_doc_suggestions
          SET render_mode = 'block'
          WHERE original_markdown LIKE #{newline_pattern}
             OR proposed_markdown LIKE #{newline_pattern}
        SQL
      end
    end
  end
end
