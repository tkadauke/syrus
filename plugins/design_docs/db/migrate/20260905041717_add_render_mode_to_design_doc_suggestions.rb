class AddRenderModeToDesignDocSuggestions < ActiveRecord::Migration[8.1]
  def up
    unless column_exists?(:design_doc_suggestions, :render_mode)
      add_column :design_doc_suggestions, :render_mode, :string, null: false, default: "inline"
    end

    suggestion_model = Class.new(ActiveRecord::Base) do
      self.table_name = "design_doc_suggestions"
    end
    marker_pattern = /\A\s{0,3}(\#{1,6}\s+|[-*+]\s+|\d+\.\s+|>\s?|```|~~~)/

    suggestion_model.find_each do |suggestion|
      values = [ suggestion.original_markdown.to_s, suggestion.proposed_markdown.to_s ]
      next unless values.any? { |value| value.include?("\n") || value.match?(marker_pattern) }

      suggestion.update_columns(render_mode: "block")
    end
  end

  def down
    remove_column :design_doc_suggestions, :render_mode if column_exists?(:design_doc_suggestions, :render_mode)
  end
end
