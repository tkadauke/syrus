class AddThroughputMetricWindowIndexes < ActiveRecord::Migration[8.1]
  # RepositoryThroughputMetricContract filters each source table by a date
  # window. Several of those columns had no usable index, so the endpoint fell
  # back to scanning the largest tables in the schema — 131 seconds observed in
  # production for one repository, 129s of it inside SQL.
  #
  # runs: the query filters state + finished_at, but the only candidate index
  # (idx_runs_provider_state_finished) leads with agent_provider, which this
  # query does not constrain, so it could not be used at all.
  INDEXES = [
    { table: :runs, columns: [ :state, :finished_at ], name: "idx_runs_state_finished_at" },
    { table: :merge_trains, columns: [ :repository_id, :finished_at ], name: "idx_merge_trains_repo_finished_at" },
    { table: :job_approvals, columns: [ :approved_at ], name: "idx_job_approvals_approved_at" }
  ].freeze

  def up
    INDEXES.each do |index|
      next if index_exists?(index[:table], index[:columns], name: index[:name])

      add_index index[:table], index[:columns], name: index[:name]
    end
  end

  def down
    INDEXES.each do |index|
      next unless index_exists?(index[:table], index[:columns], name: index[:name])

      remove_index index[:table], name: index[:name]
    end
  end
end
