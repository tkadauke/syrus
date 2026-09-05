class AddOriginToJobs < ActiveRecord::Migration[8.1]
  # Where a Job came from, as two generic core-owned columns
  # (docs/plans/plugin-model-and-component-moves.md, "Job Origin").
  #
  # `Job` records its provenance five overlapping ways today -- `kind`,
  # `input_source_id`, `external_ref`, `issue_number`, `scheduled_task_id` --
  # and each new source adds another special case to core. `origin` names the
  # plugin that created the Job ("core" for built-ins) and `origin_id` is that
  # plugin's opaque identifier for the thing that caused it. Core never parses
  # `origin_id`, which is what lets `jobs.scheduled_task_id` go away instead of
  # being relocated.
  #
  # Step 1 of the staged migration: both writable, old columns still
  # authoritative. Nothing reads these yet.
  def up
    # Bounded on purpose. These two join `state` in a composite index, and at
    # the default varchar(255) that key is 8 + 1020 + 1020 + 1020 = 3068 bytes
    # against MySQL's 3072-byte limit -- four bytes of headroom, which the next
    # person to widen a column would silently spend. An origin is a plugin
    # name; an origin_id is an issue number or a record id.
    add_column :jobs, :origin, :string, limit: 64 unless column_exists?(:jobs, :origin)
    add_column :jobs, :origin_id, :string, limit: 191 unless column_exists?(:jobs, :origin_id)

    # Backfill from whichever column is authoritative for each kind today.
    # A scheduled fire is the case this whole change exists for.
    execute <<~SQL
      UPDATE jobs SET origin = 'scheduled_tasks', origin_id = CAST(scheduled_task_id AS CHAR)
      WHERE origin IS NULL AND scheduled_task_id IS NOT NULL
    SQL

    # Issue- and PR-backed Jobs came through a source-control plugin. Without a
    # recorded input source that is GitHub polling, the only other door that
    # produces one.
    execute <<~SQL
      UPDATE jobs SET origin = 'github_source', origin_id = CAST(issue_number AS CHAR)
      WHERE origin IS NULL AND issue_number IS NOT NULL
    SQL
    execute <<~SQL
      UPDATE jobs SET origin = 'github_source', origin_id = CAST(external_pr_number AS CHAR)
      WHERE origin IS NULL AND external_pr_number IS NOT NULL
    SQL

    # Everything else -- direct prompts, main-grader sweeps, deploys -- is core
    # asking for its own work. There is no external thing to point at.
    execute "UPDATE jobs SET origin = 'core' WHERE origin IS NULL"

    # `jobs.source_ref` is persisted and indexed, and SourceRef now derives its
    # kind from `origin` -- so refs written as "scheduled_task:<id>" have to
    # become "scheduled_tasks:<id>" or Job.for_source_ref stops matching them.
    # REPLACE is one of the few string functions both MySQL and SQLite have.
    execute <<~SQL
      UPDATE jobs SET source_ref = REPLACE(source_ref, 'scheduled_task:', 'scheduled_tasks:')
      WHERE source_ref LIKE 'scheduled_task:%'
    SQL

    change_column_null :jobs, :origin, false

    unless index_exists?(:jobs, [ :repository_id, :origin, :origin_id, :state ], name: "index_jobs_on_repository_origin_state")
      add_index :jobs, [ :repository_id, :origin, :origin_id, :state ],
                name: "index_jobs_on_repository_origin_state"
    end
  end

  def down
    remove_index :jobs, name: "index_jobs_on_repository_origin_state" if index_exists?(:jobs, [ :repository_id, :origin, :origin_id, :state ], name: "index_jobs_on_repository_origin_state")
    remove_column :jobs, :origin_id if column_exists?(:jobs, :origin_id)
    remove_column :jobs, :origin if column_exists?(:jobs, :origin)
  end
end
