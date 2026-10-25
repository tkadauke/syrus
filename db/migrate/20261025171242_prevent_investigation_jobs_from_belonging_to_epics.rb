class PreventInvestigationJobsFromBelongingToEpics < ActiveRecord::Migration[8.1]
  CONSTRAINT_NAME = "chk_jobs_investigation_without_epic"

  def up
    # Investigations are standalone work. Preserve every legacy Job while
    # detaching invalid rows before the database begins enforcing the rule.
    execute <<~SQL.squish
      UPDATE jobs
      SET epic_id = NULL
      WHERE investigation = #{connection.quoted_true}
        AND epic_id IS NOT NULL
    SQL

    return if check_constraint_exists?(:jobs, name: CONSTRAINT_NAME)

    add_check_constraint :jobs,
                         "investigation = #{connection.quoted_false} OR epic_id IS NULL",
                         name: CONSTRAINT_NAME
  end

  def down
    remove_check_constraint :jobs, name: CONSTRAINT_NAME if check_constraint_exists?(:jobs, name: CONSTRAINT_NAME)
  end
end
