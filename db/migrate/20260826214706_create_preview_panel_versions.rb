class CreatePreviewPanelVersions < ActiveRecord::Migration[8.1]
  def change
    create_table :preview_panel_versions, if_not_exists: true do |t|
      t.references :preview_panel, null: false, foreign_key: true

      t.timestamps
    end
  end
end
