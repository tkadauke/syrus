class AddGhRateLimitToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :gh_rate_limit_remaining,   :integer
    add_column :users, :gh_rate_limit_limit,        :integer
    add_column :users, :gh_rate_limit_reset_at,     :datetime
    add_column :users, :gh_rate_limit_resource,     :string, limit: 32
    add_column :users, :gh_rate_limit_observed_at,  :datetime
  end
end
