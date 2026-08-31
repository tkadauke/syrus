class AddClassifierCandidateIndexToJobs < ActiveRecord::Migration[8.1]
  def change
    add_index :jobs,
              [ :repository_id, :validity, :created_at, :id ],
              name: "idx_jobs_classifier_candidates",
              if_not_exists: true
  end
end
