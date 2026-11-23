class AddWakeupChainLimit < ActiveRecord::Migration[8.1]
  # NY34: self-scheduled wakeups are essential (approval-free), so the chain
  # they form is bounded instead. Each wakeup records how many wakeups in a row
  # led to it and which wakeup's turn scheduled it.
  def change
    unless column_exists?(:app_settings, :wakeup_chain_limit)
      add_column :app_settings, :wakeup_chain_limit, :integer, default: 100, null: false
    end
    unless column_exists?(:chat_wakeups, :chain_depth)
      add_column :chat_wakeups, :chain_depth, :integer, default: 1, null: false
    end
    unless column_exists?(:chat_wakeups, :source_wakeup_id)
      add_reference :chat_wakeups, :source_wakeup, null: true, index: true, foreign_key: false
    end
  end
end
