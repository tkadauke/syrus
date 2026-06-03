class AddCredentialUserToJobs < ActiveRecord::Migration[8.1]
  def up
    add_reference :jobs, :credential_user, null: true, foreign_key: { to_table: :users } unless column_exists?(:jobs, :credential_user_id)

    execute <<~SQL.squish
      UPDATE jobs
      SET credential_user_id = user_id
      WHERE credential_user_id IS NULL
    SQL

    change_column_null :jobs, :credential_user_id, false if column_exists?(:jobs, :credential_user_id)
  end

  def down
    remove_reference :jobs, :credential_user, foreign_key: { to_table: :users } if column_exists?(:jobs, :credential_user_id)
  end
end
