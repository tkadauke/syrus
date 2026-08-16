class ReduceJobLogWriteIndexes < ActiveRecord::Migration[8.1]
  def change
    remove_index :job_logs, name: "index_job_logs_on_run_id", if_exists: true
    remove_index :job_logs, name: "idx_job_logs_run_kind_chunk_lookup", if_exists: true
  end
end
