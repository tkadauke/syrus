class AddActiveDedupKeyToWorkUnits < ActiveRecord::Migration[8.1]
  # Snapshot of WorkDefinitions::Base#lock_conflicts_enforced? at the time
  # this migration was written. A second active WorkUnit of one of these
  # kinds for the same scope is always a duplicate-materialization bug
  # (JOB-4235), never an intentional concurrent attempt, so it's safe to
  # backfill retroactively. Kinds left out here (agent_insight,
  # main_branch_repair, main_grader, replay, visual_diff, hotfix_sync,
  # promotion) keep today's more permissive "materialize, then block at
  # start" behavior.
  ACTIVE_STATES = %w[queued blocked running].freeze
  DEDUP_ENFORCED_KINDS = %w[
    initial pr_comment chat_feedback ci_failure rebase auto_merge
    external_pr_merge retry checkpoint_resume manual_visual_review manual
    resume coding_handoff local_mode_handoff manual_agentic_run
    external_pr_ingest external_pr_feedback upstream_export skill deploy
    stack_rebase merge_train job_bundle landing_validation
    merge_train_validation job_bundle_validation
  ].freeze

  class MigrationWorkUnit < ActiveRecord::Base
    self.table_name = "work_units"
  end

  def up
    add_column :work_units, :active_dedup_key, :string, limit: 512 unless column_exists?(:work_units, :active_dedup_key)
    MigrationWorkUnit.reset_column_information

    backfill_active_dedup_keys!

    unless index_exists?(:work_units, :active_dedup_key, name: "idx_work_units_active_dedup_key_unique")
      add_index :work_units, :active_dedup_key, unique: true, name: "idx_work_units_active_dedup_key_unique"
    end
  end

  def down
    remove_index :work_units, name: "idx_work_units_active_dedup_key_unique" if index_exists?(:work_units, :active_dedup_key, name: "idx_work_units_active_dedup_key_unique")
    remove_column :work_units, :active_dedup_key if column_exists?(:work_units, :active_dedup_key)
  end

  private

  # Keep only the most recently created active WorkUnit per (scope,
  # kind) tuple; leave any pre-existing sibling duplicates' key blank so
  # the unique index can be added without erroring on rows that predate
  # this guarantee. Their runtime state is untouched.
  def backfill_active_dedup_keys!
    dedup_scope
      .group_by { |unit| [ unit.scope_type, unit.scope_id, unit.kind ] }
      .each_value do |units|
        keeper = units.max_by { |unit| [ unit.created_at, unit.id ] }
        keeper.update_column(:active_dedup_key, "#{keeper.scope_type}:#{keeper.scope_id}:#{keeper.kind}")
      end
  end

  # A blank scope_id (e.g. an epic-scoped kind running for a job with no
  # epic) would stringify to the same "<scope_type>::<kind>" key across
  # otherwise-unrelated units, so exclude those rows from backfill the
  # same way WorkUnit#sync_active_dedup_key does going forward.
  def dedup_scope
    MigrationWorkUnit.where(state: ACTIVE_STATES, kind: DEDUP_ENFORCED_KINDS).where.not(scope_id: nil).to_a
  end
end
