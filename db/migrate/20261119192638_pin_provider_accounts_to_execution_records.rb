class PinProviderAccountsToExecutionRecords < ActiveRecord::Migration[8.1]
  def up
    %i[workflows runs provider_sessions].each do |table|
      add_reference table, :provider_account, null: true, foreign_key: false unless column_exists?(table, :provider_account_id)
    end

    execute <<~SQL.squish
      UPDATE workflows SET provider_account_id = (SELECT provider_accounts.id FROM provider_accounts WHERE provider_accounts.user_id = workflows.user_id AND provider_accounts.provider_key = workflows.agent_provider AND provider_accounts.position = 0 LIMIT 1) WHERE provider_account_id IS NULL
    SQL
    execute <<~SQL.squish
      UPDATE runs SET provider_account_id = COALESCE((SELECT workflows.provider_account_id FROM steps INNER JOIN workflows ON workflows.id = steps.workflow_id WHERE steps.id = runs.step_id LIMIT 1), (SELECT provider_accounts.id FROM provider_accounts WHERE provider_accounts.user_id = runs.user_id AND provider_accounts.provider_key = runs.agent_provider AND provider_accounts.position = 0 LIMIT 1)) WHERE provider_account_id IS NULL
    SQL
    execute <<~SQL.squish
      UPDATE provider_sessions SET provider_account_id = (SELECT runs.provider_account_id FROM runs WHERE provider_sessions.resumable_type = 'Run' AND runs.id = provider_sessions.resumable_id LIMIT 1) WHERE provider_account_id IS NULL
    SQL
  end

  def down
    %i[provider_sessions runs workflows].each do |table|
      remove_reference table, :provider_account, foreign_key: false if column_exists?(table, :provider_account_id)
    end
  end
end
