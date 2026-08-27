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
        label "Preset"
        bucket :preset
        operators :is

        PRESETS = %w[
          pinned in_progress paused queued inbox awaiting_approval just_failed
          stale blocked merged_this_week awaiting_epic needs_review landing_queue
          waiting_for_upstream promotion_pending delivery_needs_attention
        ].freeze

        # How far back to look for EPIC-268 delivery-track candidates
        # (`promotion_pending`) — `waiting_for_upstream`/`delivery_needs_attention`
        # key off already-persisted `JobPrLink` rows instead (a small, naturally
        # bounded table) and don't need this window.
        DELIVERY_LOOKBACK = 30.days

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
              chip_node("latest_workflow_state", "is", "running")
            )
          },
          "paused"             => -> { chip_node("has_start_blocked_reason", "is_true", nil) },
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
            chip_node("state", "is", "failed")
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
          active = scope.where(manual_paused: false)
          active.where(state: "running").where.not(id: paused_job_ids)
                .or(active.open_threads.where(id: unpaused_running_workflow_job_ids))
                .or(active.open_threads.where(id: actively_executing_job_ids))
                .or(active.where(id: running_repair_work_job_ids))
        end

        def apply_paused
          scope.open_threads.where(manual_paused: true)
               .or(scope.open_threads.where(id: paused_job_ids))
        end

        def apply_queued
          # Infrastructure workflows skip propagate_start_to_job!, leaving the job :queued while the workflow runs; exclude them so they appear in_progress instead.
          running_infra_ids = runtime_running_job_ids(trigger_kind: WorkDefinitions.lifecycle_managed_workflow_kinds)
          active = scope.where(manual_paused: false)
          active.where(state: "queued")
               .where.not(id: running_infra_ids)
               .or(active.open_threads.where.not(state: "landing").where(id: latest_workflow_job_ids("queued")))
        end

        def apply_inbox
          return scope.none unless user

          # Scope to the current user's *effective* ownership. A raw
          # `owner_user_id = user.id` silently excludes NULL-owner jobs
          # (NULL = id is never true), which dropped the operator's own
          # unowned jobs out of the inbox. effectively_owned_by falls
          # back to the creator, matching the rest of the codebase.
          owner_jobs = Job.effectively_owned_by(user)
          open = scope.effectively_owned_by(user).open_threads.without_active_runtime_work
          open.where(id: actionable_unread_feedback_ids(owner_jobs))
              .or(open.where(state: "failed").where.not(id: active_repair_work_job_ids))
              .or(open.where(id: landing_failure_ids(owner_jobs)))
              .or(open.where(id: needs_review_ids(owner_jobs)))
              .or(open.where(id: awaiting_approval_ids(owner_jobs)))
        end

        def apply_awaiting_approval
          awaiting_approval_scope(scope)
        end

        def apply_just_failed
          # A Job in Just failed should be terminal enough to require
          # operator action. Failed jobs with active repair work are still in
          # motion, so they surface as in-progress/paused from the WorkUnit
          # projection instead of as operator-terminal failures.
          scope.where(state: "failed").where.not(id: active_repair_work_job_ids)
        end

        def apply_stale
          scope.open_threads.where(updated_at: ..7.days.ago)
        end

        def apply_blocked
          open = scope.open_threads.without_active_runtime_work
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
          scope.landing_queue.without_requested_changes_attention
        end

        # A Job with an open promotion or upstream-export PR (JobPrLink role
        # promotion/upstream_export, DeliveryStatus's :waiting_for_upstream_approval
        # equivalent). Reads only `job_pr_links` — a small table written
        # exclusively by the ref-movement publish steps — so this never scans
        # the full jobs table.
        def apply_waiting_for_upstream
          scope.where(id: pending_upstream_link_job_ids)
        end

        # A Job whose delivery track has landed locally but the repository's
        # promotion/hotfix-sync configuration says there's still outbound ref
        # movement pending: promoted-but-not-yet-promoted (no promotion
        # JobPrLink yet) or landed on a non-default track under hotfix-sync.
        # Bounded to recently-closed successful Jobs (DELIVERY_LOOKBACK) in
        # repositories that have actually opted into promotion/hotfix_sync —
        # everything else short-circuits before touching DeliveryPolicy.
        def apply_promotion_pending
          scope.where(id: promotion_pending_job_ids)
        end

        # A Job whose upstream/promotion PR closed without merging —
        # DeliveryStatus's :upstream_closed_without_merge.
        def apply_delivery_needs_attention
          scope.where(id: upstream_closed_without_merge_job_ids)
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
                      ORDER BY (latest_workflows.finished_at IS NULL) DESC, latest_workflows.finished_at DESC, latest_workflows.id DESC
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
              ORDER BY (latest_workflows.finished_at IS NULL) DESC, latest_workflows.finished_at DESC, latest_workflows.id DESC
              LIMIT 1
            )
          SQL
            .select(:job_id)
        end

        def unpaused_running_workflow_job_ids
          running_work_unit_job_ids - blocked_work_unit_job_ids
        end

        def paused_job_ids
          pause_blocked_work_unit_job_ids - actively_executing_job_ids
        end

        def active_repair_work_job_ids
          @active_repair_work_job_ids ||= WorkUnits::Ownership.all_active_job_ids(kinds: WorkDefinitions.active_repair_work_kinds).to_a
        end

        def running_repair_work_job_ids
          @running_repair_work_job_ids ||= running_work_unit_job_ids(kinds: WorkDefinitions.active_repair_work_kinds)
        end

        def blocked_work_unit_job_ids
          @blocked_work_unit_job_ids ||= WorkUnits::Ownership.all_blocked_job_ids.to_a
        end

        # "Paused" means a human paused the Job or the system halted it
        # for an infra reason — not "waiting in line on a dependency".
        # That's the "Blocked" smart folder's territory (blocked_dependency_ids).
        def pause_blocked_work_unit_job_ids
          @pause_blocked_work_unit_job_ids ||=
            WorkUnits::Ownership.all_blocked_job_ids(reasons: WorkUnit::PAUSE_BLOCKED_REASONS).to_a
        end

        def runtime_running_job_ids(trigger_kind: nil, excluding_trigger_kind: nil)
          running_work_unit_job_ids(kinds: trigger_kind, excluding_kinds: excluding_trigger_kind)
        end

        def running_work_unit_job_ids(kinds: nil, excluding_kinds: nil)
          scope = WorkUnitMember.joins(:work_unit).where(work_units: { state: "running" })
          scope = scope.where(work_units: { kind: Array(kinds).map(&:to_s) }) if kinds.present?
          scope = scope.where.not(work_units: { kind: Array(excluding_kinds).map(&:to_s) }) if excluding_kinds.present?
          scope.distinct.pluck(:job_id)
        end

        def running_run_job_ids
          @running_run_job_ids ||= Run.where(state: "running").distinct.pluck(:job_id)
        end

        def actively_executing_job_ids
          @actively_executing_job_ids ||= running_run_job_ids | running_work_unit_job_ids
        end

        def awaiting_epic_ids
          Job.triaging.where(triaging_reason: "pending_epic_ref").select(:id)
        end

        def needs_review_ids(base = Job.all)
          base.where(validity: %w[ duplicate already_implemented ]).select(:id)
        end

        def landing_failure_ids(base = Job.open_threads)
          HasLandingFailure.failed_landing_scope(base.open_threads).select(:id)
        end

        def awaiting_approval_ids(base = Job.all)
          awaiting_approval_scope(base).select(:id)
        end

        def awaiting_approval_scope(base)
          base.where(state: "implemented").without_active_runtime_work
        end

        def unread_feedback_ids(base = Job.all)
          base.where.not(last_seen_comment_at: nil)
              .where("last_feedback_addressed_at IS NULL OR last_seen_comment_at > last_feedback_addressed_at")
              .select(:id)
        end

        def actionable_unread_feedback_ids(base = Job.all)
          base.where(id: unread_feedback_ids(base))
              .where.not(state: %w[ triaging queued running landing ])
              .select(:id)
        end

        def outbound_delivery_pr_links
          @outbound_delivery_pr_links ||= JobPrLink
            .where(role: [ JobPrLink::ROLE_UPSTREAM_EXPORT, JobPrLink::ROLE_PROMOTION ])
            .pluck(:job_id, :metadata)
        end

        def pending_upstream_link_job_ids
          outbound_delivery_pr_links
            .reject { |_job_id, metadata| %w[merged closed].include?(metadata.to_h["pr_state"]) }
            .map(&:first)
        end

        def upstream_closed_without_merge_job_ids
          outbound_delivery_pr_links
            .select { |_job_id, metadata| metadata.to_h["pr_state"] == "closed" }
            .map(&:first)
        end

        def promotion_pending_job_ids
          successful_closed = Job.closed_threads
            .where(closure_reason: Job::SUCCESSFUL_CLOSURE_REASONS)
            .where(updated_at: DELIVERY_LOOKBACK.ago..)
          repository_ids = successful_closed.distinct.pluck(:repository_id)
          return [] if repository_ids.empty?

          capable_policies = delivery_capable_policies_by_repository_id(repository_ids)
          return [] if capable_policies.empty?

          already_promoted_job_ids = JobPrLink.where(role: JobPrLink::ROLE_PROMOTION).distinct.pluck(:job_id).to_set

          successful_closed
            .where(repository_id: capable_policies.keys)
            .select(:id, :repository_id, :delivery_track)
            .filter_map { |job| promotion_pending_job_id_for(job, capable_policies.fetch(job.repository_id), already_promoted_job_ids) }
        end

        def promotion_pending_job_id_for(job, policy, already_promoted_job_ids)
          if policy.promotion_enabled?
            return job.id unless already_promoted_job_ids.include?(job.id)
          elsif policy.hotfix_sync_enabled? && policy.job_delivery_track(job) != SyrusYml::DEFAULT_DELIVERY_TRACK_NAME
            return job.id
          end

          nil
        end

        # Only worth a `DeliveryPolicy` (a `.syrus.yml` bare-clone read) for
        # repositories that actually have a recently-closed successful Job —
        # most repositories in a `promotion_pending` candidate set never do.
        def delivery_capable_policies_by_repository_id(repository_ids)
          Repository.where(id: repository_ids).index_by(&:id).filter_map do |id, repository|
            policy = DeliveryPolicy.for(repository: repository)
            [ id, policy ] if policy.promotion_enabled? || policy.hotfix_sync_enabled?
          end.to_h
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
