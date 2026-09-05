class CreateMockups < ActiveRecord::Migration[8.1]
  # A mockup is the first-class, listable thing an operator thinks in terms of;
  # the PreviewPanel it points at stays core, because the panel is a generic
  # multi-format viewer that other features render into too (JOB-3864).
  #
  # One row per panel: republishing a panel updates the mockup rather than
  # creating another, so MOCKUP-<id> is stable across iterations.
  def up
    create_table :mockups, if_not_exists: true do |t|
      t.references :preview_panel, null: false, index: { unique: true }
      t.references :user, null: false
      t.references :chat_session, null: true
      t.string :title, null: false, limit: 200
      t.datetime :published_at
      t.timestamps
    end

    unless index_exists?(:mockups, [ :user_id, :updated_at ], name: "index_mockups_on_user_recent")
      add_index :mockups, [ :user_id, :updated_at ], name: "index_mockups_on_user_recent"
    end
  end

  def down
    drop_table :mockups, if_exists: true
  end
end
