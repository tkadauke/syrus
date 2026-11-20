# The backfill walks each table in committed id-range batches rather than one
# table-wide UPDATE inside the migration transaction: on production, `runs`
# rows are written constantly by live workers, and a single statement that
# must lock every row outlives the InnoDB lock wait, failing db-prepare on
# every retry.
class PinProviderAccountsToExecutionRecords < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  BATCH_SIZE = 1_000

  BACKFILLS = {
    workflows: <<~SQL.squish,
      UPDATE workflows SET provider_account_id = (SELECT provider_accounts.id FROM provider_accounts WHERE provider_accounts.user_id = workflows.user_id AND provider_accounts.provider_key = workflows.agent_provider AND provider_accounts.position = 0 LIMIT 1)
    SQL
    runs: <<~SQL.squish,
      UPDATE runs SET provider_account_id = COALESCE((SELECT workflows.provider_account_id FROM steps INNER JOIN workflows ON workflows.id = steps.workflow_id WHERE steps.id = runs.step_id LIMIT 1), (SELECT provider_accounts.id FROM provider_accounts WHERE provider_accounts.user_id = runs.user_id AND provider_accounts.provider_key = runs.agent_provider AND provider_accounts.position = 0 LIMIT 1))
    SQL
    provider_sessions: <<~SQL.squish
      UPDATE provider_sessions SET provider_account_id = (SELECT runs.provider_account_id FROM runs WHERE provider_sessions.resumable_type = 'Run' AND runs.id = provider_sessions.resumable_id LIMIT 1)
    SQL
  }.freeze

  def up
    BACKFILLS.each_key do |table|
      add_reference table, :provider_account, null: true, foreign_key: false unless column_exists?(table, :provider_account_id)
    end

    BACKFILLS.each { |table, update_sql| backfill_in_batches(table, update_sql) }
  end

  def down
    %i[provider_sessions runs workflows].each do |table|
      remove_reference table, :provider_account, foreign_key: false if column_exists?(table, :provider_account_id)
    end
  end

  private

  def backfill_in_batches(table, update_sql)
    min_id, max_id = select_rows("SELECT MIN(id), MAX(id) FROM #{table}").first
    return if min_id.nil?

    (min_id.to_i..max_id.to_i).step(BATCH_SIZE) do |batch_start|
      execute "#{update_sql} WHERE #{table}.provider_account_id IS NULL " \
              "AND #{table}.id BETWEEN #{batch_start} AND #{batch_start + BATCH_SIZE - 1}"
    end
  end
end
