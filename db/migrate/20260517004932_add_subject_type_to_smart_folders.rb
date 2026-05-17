class AddSubjectTypeToSmartFolders < ActiveRecord::Migration[8.1]
  def up
    unless column_exists?(:smart_folders, :subject_type)
      add_column :smart_folders, :subject_type, :string
    end

    execute "UPDATE smart_folders SET subject_type = 'job' WHERE subject_type IS NULL"
    change_column_null :smart_folders, :subject_type, false if column_exists?(:smart_folders, :subject_type)

    remove_index :smart_folders, column: [ :user_id, :name ], if_exists: true
    add_index :smart_folders, [ :user_id, :subject_type, :name ], unique: true unless index_exists?(:smart_folders, [ :user_id, :subject_type, :name ])
    add_index :smart_folders, [ :kind, :subject_type ] unless index_exists?(:smart_folders, [ :kind, :subject_type ])
  end

  def down
    remove_index :smart_folders, column: [ :kind, :subject_type ], if_exists: true
    remove_index :smart_folders, column: [ :user_id, :subject_type, :name ], if_exists: true
    add_index :smart_folders, [ :user_id, :name ], unique: true unless index_exists?(:smart_folders, [ :user_id, :name ])
    remove_column :smart_folders, :subject_type if column_exists?(:smart_folders, :subject_type)
  end
end
