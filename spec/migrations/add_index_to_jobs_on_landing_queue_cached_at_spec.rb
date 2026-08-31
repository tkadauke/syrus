require "rails_helper"

RSpec.describe "AddIndexToJobsOnLandingQueueCachedAt", :ci_only do
  it "adds an index covering LandingQueueProcessor#clear_stale_snapshot!'s global sweep" do
    expect(
      ActiveRecord::Base.connection.index_exists?(
        :jobs, [ :landing_queue_cached_at, :state ],
        name: "index_jobs_on_landing_queue_cached_at_and_state"
      )
    ).to eq(true)
  end
end
