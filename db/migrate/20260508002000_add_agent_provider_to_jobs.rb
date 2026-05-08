class AddAgentProviderToJobs < ActiveRecord::Migration[8.1]
  def up
    add_column :jobs, :agent_provider, :string

    execute <<~SQL.squish
      UPDATE jobs
      SET agent_provider = COALESCE(
        (
          SELECT workflows.agent_provider
          FROM workflows
          WHERE workflows.job_id = jobs.id
          ORDER BY workflows.created_at DESC
          LIMIT 1
        ),
        (
          SELECT users.agent_provider
          FROM users
          WHERE users.id = jobs.user_id
        ),
        'claude'
      )
      WHERE agent_provider IS NULL
    SQL

    change_column_null :jobs, :agent_provider, false
  end

  def down
    remove_column :jobs, :agent_provider
  end
end
