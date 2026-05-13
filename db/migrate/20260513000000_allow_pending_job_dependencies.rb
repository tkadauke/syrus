class AllowPendingJobDependencies < ActiveRecord::Migration[8.1]
  def change
    # A pending row carries the parsed reference (owner / repo / issue
    # number) but no resolved depends_on_job_id yet — the target Job
    # didn't exist when this Job was ingested. When the target lands
    # later, Job.resolve_pending_dependencies! promotes the row.
    change_column_null :job_dependencies, :depends_on_job_id, true

    add_column :job_dependencies, :unresolved_owner, :string
    add_column :job_dependencies, :unresolved_repo, :string
    add_column :job_dependencies, :unresolved_number, :integer

    add_index :job_dependencies,
              [ :unresolved_owner, :unresolved_repo, :unresolved_number ],
              where: "unresolved_owner IS NOT NULL",
              name: "index_job_deps_on_unresolved_reference"

    # Uniqueness for pending rows — the existing unique index on
    # (job_id, depends_on_job_id) doesn't cover NULL depends_on_job_id
    # in MySQL.
    add_index :job_dependencies,
              [ :job_id, :unresolved_owner, :unresolved_repo, :unresolved_number ],
              unique: true,
              where: "depends_on_job_id IS NULL",
              name: "index_job_deps_on_unique_unresolved_per_job"
  end
end
