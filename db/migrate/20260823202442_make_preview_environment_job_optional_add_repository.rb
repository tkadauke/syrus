class MakePreviewEnvironmentJobOptionalAddRepository < ActiveRecord::Migration[8.1]
  def up
    change_column_null :preview_environments, :job_id, true

    unless column_exists?(:preview_environments, :repository_id)
      add_reference :preview_environments, :repository, null: true, foreign_key: true
    end
  end

  def down
    execute "DELETE FROM preview_environments WHERE job_id IS NULL"
    change_column_null :preview_environments, :job_id, false

    if column_exists?(:preview_environments, :repository_id)
      remove_reference :preview_environments, :repository, foreign_key: true
    end
  end
end
