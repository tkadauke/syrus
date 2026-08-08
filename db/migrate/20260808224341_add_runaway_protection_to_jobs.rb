class AddRunawayProtectionToJobs < ActiveRecord::Migration[8.1]
  def up
    add_column :jobs, :runaway_protection, :string unless column_exists?(:jobs, :runaway_protection)
    add_column :jobs, :runaway_protection_at, :datetime unless column_exists?(:jobs, :runaway_protection_at)
  end

  def down
    remove_column :jobs, :runaway_protection_at if column_exists?(:jobs, :runaway_protection_at)
    remove_column :jobs, :runaway_protection if column_exists?(:jobs, :runaway_protection)
  end
end
