class AddJobProviderSettingToJobs < ActiveRecord::Migration[8.1]
  def up
    add_column :jobs, :job_provider_setting, :string, default: "default" unless column_exists?(:jobs, :job_provider_setting)

    execute "UPDATE jobs SET job_provider_setting = 'default' WHERE job_provider_setting IS NULL"

    change_column_null :jobs, :job_provider_setting, false

    backfill_workflow_agent_providers
  end

  def down
    remove_column :jobs, :job_provider_setting if column_exists?(:jobs, :job_provider_setting)
  end

  private

  def backfill_workflow_agent_providers
    execute <<~SQL.squish
      UPDATE workflows
      SET agent_provider = (
        SELECT runs.agent_provider
        FROM steps
        INNER JOIN runs ON runs.step_id = steps.id
        WHERE steps.workflow_id = workflows.id
          AND runs.agent_provider IS NOT NULL
          AND runs.agent_provider <> ''
        ORDER BY runs.created_at ASC, runs.id ASC
        LIMIT 1
      )
      WHERE (agent_provider IS NULL OR agent_provider = '')
        AND EXISTS (
          SELECT 1
          FROM steps
          INNER JOIN runs ON runs.step_id = steps.id
          WHERE steps.workflow_id = workflows.id
            AND runs.agent_provider IS NOT NULL
            AND runs.agent_provider <> ''
        )
    SQL

    execute <<~SQL.squish
      UPDATE workflows
      SET agent_provider = (
        SELECT jobs.agent_provider
        FROM jobs
        WHERE jobs.id = workflows.job_id
      )
      WHERE (agent_provider IS NULL OR agent_provider = '')
    SQL
  end
end
