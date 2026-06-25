class AddEpicTitleToJobs < ActiveRecord::Migration[8.1]
  def up
    add_column :jobs, :epic_title, :string unless column_exists?(:jobs, :epic_title)

    execute <<~SQL.squish
      UPDATE jobs
      SET epic_title = (
        SELECT epics.title
        FROM epics
        WHERE epics.id = jobs.epic_id
      )
      WHERE epic_id IS NOT NULL
        AND epic_title IS NULL
    SQL
  end

  def down
    remove_column :jobs, :epic_title if column_exists?(:jobs, :epic_title)
  end
end
