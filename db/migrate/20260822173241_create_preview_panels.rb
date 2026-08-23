class CreatePreviewPanels < ActiveRecord::Migration[8.1]
  def change
    create_table :preview_panels, if_not_exists: true do |t|
      t.references :chat_session, null: false
      t.string :title, null: false
      t.string :state, null: false, default: "open"

      t.timestamps
    end

    add_index :preview_panels, :state unless index_exists?(:preview_panels, :state)
  end
end
