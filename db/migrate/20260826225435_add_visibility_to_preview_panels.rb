class AddVisibilityToPreviewPanels < ActiveRecord::Migration[8.1]
  def change
    unless column_exists?(:preview_panels, :visibility)
      add_column :preview_panels, :visibility, :string, null: false, default: "private"
    end
  end
end
