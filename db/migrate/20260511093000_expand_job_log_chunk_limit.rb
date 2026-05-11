class ExpandJobLogChunkLimit < ActiveRecord::Migration[8.1]
  def change
    change_column :job_logs, :chunk, :text, limit: 16.megabytes - 1, null: false
  end
end
