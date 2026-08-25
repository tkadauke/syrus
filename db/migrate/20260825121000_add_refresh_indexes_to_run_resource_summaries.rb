class AddRefreshIndexesToRunResourceSummaries < ActiveRecord::Migration[8.1]
  def change
    add_index :run_resource_summaries,
              [ :retention_limited, :finished_at, :id ],
              name: "idx_run_resource_summaries_refresh_finished",
              if_not_exists: true

    add_index :run_resource_summaries,
              [ :retention_limited, :created_at, :id ],
              name: "idx_run_resource_summaries_refresh_created",
              if_not_exists: true
  end
end
