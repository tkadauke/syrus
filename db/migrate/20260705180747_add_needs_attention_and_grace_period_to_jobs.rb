class AddNeedsAttentionAndGracePeriodToJobs < ActiveRecord::Migration[8.1]
  def up
    add_column :jobs, :needs_attention, :boolean, default: false, null: false unless column_exists?(:jobs, :needs_attention)
    add_column :jobs, :needs_attention_reason, :string unless column_exists?(:jobs, :needs_attention_reason)
    add_column :jobs, :needs_attention_since, :datetime unless column_exists?(:jobs, :needs_attention_since)
    add_column :jobs, :grace_period_expires_at, :datetime unless column_exists?(:jobs, :grace_period_expires_at)

    add_index :jobs, :needs_attention unless index_exists?(:jobs, :needs_attention)
    add_index :jobs, :grace_period_expires_at unless index_exists?(:jobs, :grace_period_expires_at)
  end

  def down
    remove_index :jobs, :grace_period_expires_at if index_exists?(:jobs, :grace_period_expires_at)
    remove_index :jobs, :needs_attention if index_exists?(:jobs, :needs_attention)

    remove_column :jobs, :grace_period_expires_at if column_exists?(:jobs, :grace_period_expires_at)
    remove_column :jobs, :needs_attention_since if column_exists?(:jobs, :needs_attention_since)
    remove_column :jobs, :needs_attention_reason if column_exists?(:jobs, :needs_attention_reason)
    remove_column :jobs, :needs_attention if column_exists?(:jobs, :needs_attention)
  end
end
