module Filters
  module Chips
    module Jobs
      # Preset macro chip — value selects a named composite filter
      # (pinned / in_progress / queued / inbox / awaiting_approval / just_failed /
      # stale / blocked / merged_this_week / awaiting_epic /
      # needs_review / landing_queue). Each
      # preset compiles to whatever sub-scope it needs; the UI will
      # eventually let operators "expand" a preset chip into its
      # primitive sub-chips for further editing.
      class Attention < Base
        filter_name "attention"
        label "Attention preset"
        bucket :preset
        operators :is

        PRESETS = %w[
          pinned in_progress queued inbox awaiting_approval just_failed
          stale blocked merged_this_week awaiting_epic needs_review landing_queue
        ].freeze

        values(*PRESETS)

        # Static expansions: maps preset value → AST sub-tree of
        # primitive chips. The chip-bar UI's "Expand" button replaces a
        # preset chip with these primitives so operators can tweak the
        # underlying filter (e.g., bump the staleness window from 7 to
        # 14 days, or add a NOT to one branch of `blocked`). Expansions
        # are intentionally lossy: they capture the most common reading
        # of the preset, not every edge case in `apply_*`. Re-selecting
        # the preset is always available if the expansion drifts.
        #
        # Presets without a clean primitive mapping return nil — the
        # UI hides the Expand button for those.
        EXPANSIONS = {
          "pinned"             => -> { chip_node("pinned_by_me", "is_true", nil) },
          "in_progress"        => -> {
            or_node(
              chip_node("state", "is", "running"),
              and_node(
                chip_node("state", "is", "landing"),
                chip_node("latest_workflow_state", "is", "running")
              ),
              and_node(
                chip_node("latest_workflow_trigger_kind", "is", "rebase"),
                chip_node("latest_workflow_state", "is", "running")
              )
            )
          },
          "queued"             => -> {
            or_node(
              chip_node("state", "is", "queued"),
              chip_node("latest_workflow_state", "is", "queued")
            )
          },
          # `inbox` is the union of actionable operator work: review,
          # repair, or feedback that is not already being handled by an
          # active workflow.
          "inbox"              => -> {
            and_node(
              chip_node("state", "is", "open"),
              or_node(
                and_node(
                  chip_node("has_unread_feedback", "is_true", nil),
                  chip_node("state", "is_none_of", %w[triaging queued running landing])
                ),
                chip_node("state", "is", "failed"),
                chip_node("has_landing_failure", "is_true", nil),
                chip_node("validity", "is_one_of", %w[duplicate already_implemented]),
                chip_node("state", "is", "implemented")
              )
            )
          },
          "awaiting_approval"  => -> { chip_node("state", "is", "implemented") },
          "just_failed"        => -> {
            or_node(
              chip_node("state", "is", "failed"),
              chip_node("has_landing_failure", "is_true", nil)
            )
          },
          "stale"              => -> {
            and_node(
              chip_node("state", "is", "open"),
              chip_node("updated_at", "more_than_ago", { "n" => 7, "unit" => "days" })
            )
          },
          "blocked"            => -> {
            and_node(
              chip_node("state", "is", "open"),
              or_node(
                chip_node("has_blocked_deps", "is_true", nil),
                chip_node("pr_mergeable", "is_false", nil)
              )
            )
          },
          "merged_this_week"   => -> {
            and_node(
              chip_node("state", "is", "closed"),
              chip_node("closure_reason", "is_one_of", %w[pr_merged external_pr_merged]),
              chip_node("finished_at", "within_last", { "n" => 7, "unit" => "days" })
            )
          },
          "awaiting_epic"      => -> { chip_node("triaging_reason", "is", "pending_epic_ref") },
          "needs_review"       => -> {
            and_node(
              chip_node("state", "is", "open"),
              chip_node("validity", "is_one_of", %w[duplicate already_implemented])
            )
          }
        }.freeze

        def self.expansion_for(preset_value)
          builder = EXPANSIONS[preset_value.to_s]
          builder&.call
        end

        # Convenience for the Schema serializer: a hash of all
        # expandable preset values → their AST sub-trees, suitable for
        # JSON-encoding into the chip-bar metadata.
        def self.expansions
          EXPANSIONS.transform_values(&:call)
        end

        def self.chip_node(field, op, value)
          { "field" => field, "op" => op, "value" => value }
        end

        def self.and_node(*children)
          { "and" => children }
        end

        def self.or_node(*children)
          { "or" => children }
        end

        def apply
          unsupported_op! unless op == :is

          preset = value.to_s
          return scope unless PRESETS.include?(preset)

          send("apply_#{preset}")
        end

        private

        def apply_pinned
          return scope unless user

          scope.joins(:job_pins).where(job_pins: { user_id: user.id })
        end

        def apply_in_progress
          # Phase 4 simplification: Job.state is now authoritative.
          # `:running` covers initial/retry/pr_comment/ci_failure
          # workflow execution. `:landing` starts before the auto_merge
          # Workflow leaves :queued, so only count landing work here once
          # the active Workflow is actually running. Rebase workflows can
          # run while the Job is deferred back to :approved, so include
          # those explicitly.
          running_workflow_job_ids = latest_workflow_job_ids("running")
          running_rebase_job_ids = latest_workflow_job_ids("running", trigger_kind: "rebase")

          scope.where(state: "running")
               .or(scope.where(state: "landing", id: running_workflow_job_ids))
               .or(scope.open_threads.where(id: running_rebase_job_ids))
        end

        def apply_queued
          queued_workflow_job_ids = latest_workflow_job_ids("queued")
          scope.where(state: "queued").or(scope.open_threads.where(id: queued_workflow_job_ids))
        end

        def apply_inbox
          open = scope.open_threads.without_active_workflows
          open.where(id: actionable_unread_feedback_ids)
              .or(open.where(state: "failed"))
              .or(open.where.not(landing_failure_reason: nil))
              .or(open.where(id: needs_review_ids))
              .or(open.where(id: awaiting_approval_ids))
        end

        def apply_awaiting_approval
          scope.where(id: awaiting_approval_ids)
        end

        def apply_just_failed
          # Phase 4 simplification: a failed workflow now propagates
          # to Job.state = :failed (Workflow#fail's after-callback),
          # so we can read the Job state directly instead of joining
          # workflows.
          scope.where(state: "failed").or(scope.open_threads.where.not(landing_failure_reason: nil))
        end

        def apply_stale
          scope.open_threads.where(updated_at: ..7.days.ago)
        end

        def apply_blocked
          open = scope.open_threads
          open.where(id: blocked_dependency_ids).or(open.where(pr_mergeable: false))
        end

        def apply_merged_this_week
          scope.closed_threads
               .where(closure_reason: %w[ pr_merged external_pr_merged ])
               .where(finished_at: 7.days.ago..)
        end

        def apply_awaiting_epic
          scope.where(id: awaiting_epic_ids)
        end

        def apply_needs_review
          scope.open_threads.where(id: needs_review_ids)
        end

        def apply_landing_queue
          scope.landing_queue
        end

        def latest_failed_run_ids
          Run.where(state: "failed")
             .where(<<~SQL.squish)
               runs.id = (
                 SELECT latest_runs.id FROM runs latest_runs
                 WHERE latest_runs.job_id = runs.job_id
                 ORDER BY latest_runs.created_at DESC, latest_runs.id DESC
                 LIMIT 1
               )
             SQL
             .select(:job_id)
        end

        def latest_workflow_failed_ids
          Workflow.where(state: "failed")
                  .where(<<~SQL.squish)
                    workflows.id = (
                      SELECT latest_workflows.id FROM workflows latest_workflows
                      WHERE latest_workflows.job_id = workflows.job_id
                      ORDER BY latest_workflows.created_at DESC, latest_workflows.id DESC
                      LIMIT 1
                    )
                  SQL
                  .select(:job_id)
        end

        def latest_workflow_job_ids(states, trigger_kind: nil)
          relation = Workflow.where(state: Array(states))
          relation = relation.where(trigger_kind: trigger_kind) if trigger_kind
          relation.where(<<~SQL.squish)
            workflows.id = (
              SELECT latest_workflows.id FROM workflows latest_workflows
              WHERE latest_workflows.job_id = workflows.job_id
              ORDER BY latest_workflows.created_at DESC, latest_workflows.id DESC
              LIMIT 1
            )
          SQL
            .select(:job_id)
        end

        def awaiting_epic_ids
          Job.triaging.where(triaging_reason: "pending_epic_ref").select(:id)
        end

        def needs_review_ids
          Job.where(validity: %w[ duplicate already_implemented ]).select(:id)
        end

        def awaiting_approval_ids
          Job.where(state: "implemented").without_active_workflows.select(:id)
        end

        def unread_feedback_ids
          Job.where.not(last_seen_comment_at: nil)
             .where("last_feedback_addressed_at IS NULL OR last_seen_comment_at > last_feedback_addressed_at")
             .select(:id)
        end

        def actionable_unread_feedback_ids
          Job.where(id: unread_feedback_ids)
             .where.not(state: %w[ triaging queued running landing ])
             .select(:id)
        end

        def blocked_dependency_ids
          successful = Job.closed_threads.where(closure_reason: Job::SUCCESSFUL_CLOSURE_REASONS)
          done_epics = Epic.where(state: "done")
          JobDependency.pending
                       .or(JobDependency.resolved.where.not(depends_on_job_id: successful.select(:id)))
                       .or(JobDependency.where.not(depends_on_epic_id: nil).where.not(depends_on_epic_id: done_epics.select(:id)))
                       .select(:job_id)
        end
      end
    end
  end
end
