class AddSubjectTypeToSmartFolders < ActiveRecord::Migration[8.1]
  OLD_UNIQUE_INDEX = "index_smart_folders_on_user_id_and_name"
  NEW_UNIQUE_INDEX = "index_smart_folders_on_user_id_name_subject_type"
  SUBJECT_USER_INDEX = "index_smart_folders_on_subject_type_and_user_id"

  def up
    unless column_exists?(:smart_folders, :subject_type)
      add_column :smart_folders, :subject_type, :string, limit: 16, default: "job", null: false
    end

    execute "UPDATE smart_folders SET subject_type = 'job' WHERE subject_type IS NULL"
    resolve_subject_name_conflicts!

    if index_exists?(:smart_folders, [ :user_id, :name ], name: OLD_UNIQUE_INDEX)
      remove_index :smart_folders, name: OLD_UNIQUE_INDEX
    end

    unless index_exists?(:smart_folders, [ :user_id, :name, :subject_type ], name: NEW_UNIQUE_INDEX)
      add_index :smart_folders, [ :user_id, :name, :subject_type ], unique: true, name: NEW_UNIQUE_INDEX
    end

    unless index_exists?(:smart_folders, [ :subject_type, :user_id ], name: SUBJECT_USER_INDEX)
      add_index :smart_folders, [ :subject_type, :user_id ], name: SUBJECT_USER_INDEX
    end
  end

  def down
    if index_exists?(:smart_folders, [ :subject_type, :user_id ], name: SUBJECT_USER_INDEX)
      remove_index :smart_folders, name: SUBJECT_USER_INDEX
    end

    if index_exists?(:smart_folders, [ :user_id, :name, :subject_type ], name: NEW_UNIQUE_INDEX)
      remove_index :smart_folders, name: NEW_UNIQUE_INDEX
    end

    unless index_exists?(:smart_folders, [ :user_id, :name ], name: OLD_UNIQUE_INDEX)
      add_index :smart_folders, [ :user_id, :name ], unique: true, name: OLD_UNIQUE_INDEX
    end

    remove_column :smart_folders, :subject_type if column_exists?(:smart_folders, :subject_type)
  end

  private

  def resolve_subject_name_conflicts!
    grouped_smart_folders.each_value do |rows|
      rows.drop(1).each do |row|
        execute <<~SQL.squish
          UPDATE smart_folders
          SET name = #{quote(unique_jobs_name(row))}
          WHERE id = #{row.fetch("id")}
        SQL
      end
    end
  end

  def grouped_smart_folders
    select_all("SELECT id, user_id, name, subject_type FROM smart_folders ORDER BY id").to_a
      .group_by { |row| [ row.fetch("user_id"), row.fetch("name"), row.fetch("subject_type") ] }
      .select { |_key, rows| rows.size > 1 }
  end

  def unique_jobs_name(row)
    candidate = "#{row.fetch("name")} (Jobs)"
    return candidate unless name_exists_for_subject?(candidate, row)

    "#{row.fetch("name")} (Jobs #{row.fetch("id")})"
  end

  def name_exists_for_subject?(name, row)
    user_clause = row["user_id"].nil? ? "user_id IS NULL" : "user_id = #{row.fetch("user_id")}"
    select_value(<<~SQL.squish)
      SELECT 1 FROM smart_folders
      WHERE #{user_clause}
        AND subject_type = #{quote(row.fetch("subject_type"))}
        AND name = #{quote(name)}
      LIMIT 1
    SQL
  end
end
