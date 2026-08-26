class AddRefreshIndexesToRunResourceSummaries < ActiveRecord::Migration[8.1]
  def change
    unless index_exists?(:run_resource_summaries, [ :retention_limited, :finished_at, :id ], name: "idx_run_resource_summaries_refresh_finished")
      add_index :run_resource_summaries,
                [ :retention_limited, :finished_at, :id ],
                name: "idx_run_resource_summaries_refresh_finished"
    end

    unless index_exists?(:run_resource_summaries, [ :retention_limited, :created_at, :id ], name: "idx_run_resource_summaries_refresh_created")
      add_index :run_resource_summaries,
                [ :retention_limited, :created_at, :id ],
                name: "idx_run_resource_summaries_refresh_created"
    end
  end
end
