class DropRepositoryNotes < ActiveRecord::Migration[8.1]
  def change
    drop_table :repository_notes, if_exists: true
  end
end
