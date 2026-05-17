module Filters
  module Chips
    module Jobs
      # Preset macro chip — value selects a named composite filter
      # (pinned / in_progress / inbox / awaiting_approval / just_failed /
      # in_review / stale / blocked / merged_this_week / awaiting_epic /
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
          pinned in_progress inbox awaiting_approval just_failed in_review
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
        # Presets without a clean primitive mapping (`inbox`, which
        # depends on awaiting_operator state that has no chip) return
        # nil — the UI hides the Expand button for those.
        EXPANSIONS = {
          "pinned"             => -> { chip_node("pinned_by_me", "is_true", nil) },
          "in_progress"        => -> {
            and_node(
              chip_node("state", "is", "open"),
              chip_node("has_active_run", "is_true", nil)
            )
          },
          # `inbox` is the union of every reason a Job might be sitting
          # in the operator's queue. apply_inbox also includes
          # `awaiting_operator_ids` (runs in operator-question state),
          # which has no primitive chip — the expansion is intentionally
          # lossy on that branch. Re-selecting the preset is always
          # available if the expansion misses a Job the apply scope
          # would have caught.
          "inbox"              => -> {
            and_node(
              chip_node("state", "is", "open"),
              or_node(
                chip_node("has_unread_feedback", "is_true", nil),
                chip_node("latest_run_state", "is", "failed"),
                chip_node("triaging_reason", "is", "pending_epic_ref"),
                chip_node("validity", "is_one_of", %w[duplicate already_implemented]),
                chip_node("state", "is", "implemented")
              )
            )
          },
          "awaiting_approval"  => -> { chip_node("state", "is", "implemented") },
          "just_failed"        => -> {
            and_node(
              chip_node("state", "is", "open"),
              chip_node("latest_run_state", "is", "failed")
            )
          },
          "in_review"          => -> {
            and_node(
              chip_node("state", "is", "open"),
              chip_node("pr_present", "is_true", nil),
              chip_node("latest_workflow_state", "is", "succeeded")
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
          scope.open_threads.where(id: Workflow.active.select(:job_id))
        end

        def apply_inbox
          open = scope.open_threads
          open.where(id: awaiting_operator_ids)
              .or(open.where(id: unread_feedback_ids))
              .or(open.where(id: latest_failed_run_ids))
              .or(open.where(id: awaiting_epic_ids))
              .or(open.where(id: needs_review_ids))
              .or(open.where(id: awaiting_approval_ids))
        end

        def apply_awaiting_approval
          scope.where(id: awaiting_approval_ids)
        end

        def apply_just_failed
          scope.open_threads.where(id: latest_failed_run_ids)
        end

        def apply_in_review
          scope.open_threads.with_pr.where(id: latest_workflow_succeeded_ids)
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

        def awaiting_operator_ids
          Run.where(state: "awaiting_operator").select(:job_id)
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

        def latest_workflow_succeeded_ids
          Workflow.where(state: "succeeded")
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

        def awaiting_epic_ids
          Job.triaging.where(triaging_reason: "pending_epic_ref").select(:id)
        end

        def needs_review_ids
          Job.where(validity: %w[ duplicate already_implemented ]).select(:id)
        end

        def awaiting_approval_ids
          Job.where(state: "implemented").select(:id)
        end

        def unread_feedback_ids
          Job.where.not(last_seen_comment_at: nil)
             .where("last_feedback_addressed_at IS NULL OR last_seen_comment_at > last_feedback_addressed_at")
             .select(:id)
        end

        def blocked_dependency_ids
          successful = Job.closed_threads.where(closure_reason: Job::SUCCESSFUL_CLOSURE_REASONS)
          JobDependency.pending
                       .or(JobDependency.resolved.where.not(depends_on_job_id: successful.select(:id)))
                       .select(:job_id)
        end
      end
    end
  end
end
