class AddClaimToJobs < ActiveRecord::Migration[8.1]
  def up
    unless column_exists?(:jobs, :claimed_by_user_id)
      add_reference :jobs, :claimed_by_user, null: true, foreign_key: { to_table: :users }
    end
    add_column :jobs, :claimed_at, :datetime unless column_exists?(:jobs, :claimed_at)
    add_index :jobs, :claimed_at unless index_exists?(:jobs, :claimed_at)
  end

  def down
    remove_index :jobs, :claimed_at if index_exists?(:jobs, :claimed_at)
    remove_column :jobs, :claimed_at if column_exists?(:jobs, :claimed_at)
    remove_reference :jobs, :claimed_by_user, foreign_key: { to_table: :users } if column_exists?(:jobs, :claimed_by_user_id)
  end
end
