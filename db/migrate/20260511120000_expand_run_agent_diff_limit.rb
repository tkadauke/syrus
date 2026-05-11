class ExpandRunAgentDiffLimit < ActiveRecord::Migration[8.1]
  def change
    change_column :runs, :agent_diff, :text, limit: 16.megabytes - 1
  end
end
