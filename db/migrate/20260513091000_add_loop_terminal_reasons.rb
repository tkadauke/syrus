class AddLoopTerminalReasons < ActiveRecord::Migration[8.1]
  def change
    add_column :workflows, :failure_reason, :string
    add_column :steps, :cancellation_reason, :string
  end
end
