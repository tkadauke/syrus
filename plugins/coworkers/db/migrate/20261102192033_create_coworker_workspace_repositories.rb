class CreateCoworkerWorkspaceRepositories < ActiveRecord::Migration[8.1]
  def up
    create_table :coworker_workspace_repositories, if_not_exists: true do |t|
      t.references :repository, null: false, index: { unique: true }
      t.timestamps
    end

    # Completed provisioning records let us distinguish registrations created
    # during provisioning from older registrations that were merely reused.
    execute <<~SQL.squish
      INSERT INTO coworker_workspace_repositories (repository_id, created_at, updated_at)
      SELECT DISTINCT repositories.id, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM repositories
      INNER JOIN coworker_provisioning_attempts
        ON LOWER(repositories.owner) = LOWER(coworker_provisioning_attempts.remote_owner)
        AND LOWER(repositories.name) = LOWER(coworker_provisioning_attempts.remote_name)
      WHERE coworker_provisioning_attempts.state = 'completed'
        AND coworker_provisioning_attempts.coworker_id IS NOT NULL
        AND repositories.created_at >= coworker_provisioning_attempts.created_at
        AND repositories.created_at <= coworker_provisioning_attempts.completed_at
        AND NOT EXISTS (
          SELECT 1 FROM coworker_workspace_repositories
          WHERE coworker_workspace_repositories.repository_id = repositories.id
        )
    SQL
  end

  def down
    drop_table :coworker_workspace_repositories, if_exists: true
  end
end
