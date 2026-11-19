class EnlargeAdminActionParams < ActiveRecord::Migration[8.1]
  # An operator action's audit row embeds the before/after repair snapshots,
  # and a merge train's snapshot -- every member Job and Workflow -- outgrew
  # MySQL TEXT's 64 KB. The audit insert failed after the action had already
  # run, so the API answered 500 for work that happened. MEDIUMTEXT holds
  # 16 MB; AdminAction.log! keeps an oversized row under that.
  #
  # SQLite ignores the limit, so dev/test see no schema change.
  def up
    return unless mysql? && column_exists?(:admin_actions, :params)

    change_column :admin_actions, :params, :text, limit: 16.megabytes
  end

  def down
    return unless mysql? && column_exists?(:admin_actions, :params)

    change_column :admin_actions, :params, :text
  end

  private

  def mysql?
    connection.adapter_name.downcase.include?("mysql")
  end
end
