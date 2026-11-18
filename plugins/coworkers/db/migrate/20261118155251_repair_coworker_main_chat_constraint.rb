class RepairCoworkerMainChatConstraint < ActiveRecord::Migration[8.1]
  OLD_INDEX = "index_coworker_chats_one_main"
  GENERATED_COLUMN = :main_coworker_id
  NEW_INDEX = "index_coworker_chats_on_main_coworker_id"

  def up
    remove_index :coworker_chats, name: OLD_INDEX if index_exists?(:coworker_chats, name: OLD_INDEX)
    unless column_exists?(:coworker_chats, GENERATED_COLUMN)
      add_column :coworker_chats, GENERATED_COLUMN, :bigint,
        as: "CASE WHEN role = 'main' THEN coworker_id ELSE NULL END", stored: true
    end
    add_index :coworker_chats, GENERATED_COLUMN, unique: true, name: NEW_INDEX unless index_exists?(:coworker_chats, name: NEW_INDEX)
  end

  def down
    remove_index :coworker_chats, name: NEW_INDEX if index_exists?(:coworker_chats, name: NEW_INDEX)
    remove_column :coworker_chats, GENERATED_COLUMN if column_exists?(:coworker_chats, GENERATED_COLUMN)
    add_index :coworker_chats, :coworker_id, unique: true, where: "role = 'main'", name: OLD_INDEX unless index_exists?(:coworker_chats, name: OLD_INDEX)
  end
end
