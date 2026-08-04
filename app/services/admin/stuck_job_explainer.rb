require "set"

module Admin
  # Single-Job diagnostic payload for chat/admin operators. Unlike
  # Admin::StuckItems, this always explains the requested Job, even when it is
  # not currently in the global stuck watchlist.
  class StuckJobExplainer
    def self.call(job, github_client: nil) = new(job, github_client: github_client).call

    def initialize(job, github_client: nil)
      @job = job
      @github_client = github_client
    end

    def call
      payload = {
        job: job_payload,
        stuck: stuck_items.any?,
        issues: issues_payload,
        stuck_list: stuck_list_payload,
        workflows: workflows_payload,
        runs: runs_payload,
        dependencies: dependencies_payload,
        landing: landing_payload,
        empty_reconciliation: empty_reconciliation_payload
      }
      payload[:recommended_action] = recommended_action(payload)
      payload[:human_summary] = human_summary(payload)
      payload
    end

    private

    attr_reader :job

    def job_payload
      {
        id: job.id,
        slug: job.slug,
        kind: job.kind,
        state: job.state,
        title: job.issue_title,
        issue_title: job.issue_title,
        branch_name: job.branch_name,
        pr_number: job.pr_number || job.external_pr_number,
        internal_pr_number: job.pr_number,
        external_pr_number: job.external_pr_number,
        closure_reason: job.closure_reason,
        landing_failure_reason: job.landing_failure_reason,
        created_at: job.created_at&.iso8601,
        updated_at: job.updated_at&.iso8601
      }
    end

    def stuck_list_payload
      {
        listed: stuck_items.any?,
        items: stuck_items.map do |item|
          {
            kind: item.kind.to_s,
            severity: item.severity.to_s,
            attention_state: item.attention_state.to_s,
            detail: item.detail,
            workflow_id: item.workflow&.id,
            run_id: item.run&.id,
            repair_plan: item.repair_plan&.as_json
          }
        end
      }
    end

    def issues_payload
      stuck_items.map do |item|
        Admin::StuckItemPayload.serialize(item: item, include_actions: false)
      end
    end

    def stuck_items
      @stuck_items ||= Admin::StuckItems.for_job(job)
    end

    def workflows_payload
      workflows = job.workflows.includes(steps: [ runs: [ :run_diagnostic, :run_failure_classification, :job_logs ] ])
                     .reorder(created_at: :asc, id: :asc)
                     .to_a
      active = workflows.select { |workflow| workflow.state.in?(%w[queued running]) }
      queued = workflows.select(&:queued?)
      failed = workflows.select(&:failed?)
      terminal = workflows.select { |workflow| workflow.state.in?(%w[succeeded failed cancelled]) }
      latest = job.latest_workflow

      {
        latest: workflow_payload(latest),
        active: active.map { |workflow| workflow_payload(workflow) },
        queued: queued.map { |workflow| workflow_payload(workflow) },
        failed: failed.map { |workflow| workflow_payload(workflow) },
        queued_stale_behind_terminal: queued_stale_behind_terminal?(queued, terminal)
      }
    end

    def workflow_payload(workflow)
      return nil unless workflow

      runs = workflow.runs.to_a
      failed_run = runs.select(&:failed?).max_by { |run| [ run.finished_at || run.updated_at || run.created_at, run.id ] }
      {
        id: workflow.id,
        trigger_kind: workflow.trigger_kind,
        state: workflow.state,
        failure_reason: workflow.failure_reason.presence || workflow.artifact("failure_reason").presence,
        run_count: runs.size,
        latest_run_id: runs.max_by { |run| [ run.created_at || Time.zone.at(0), run.id ] }&.id,
        failed_run: failed_run_payload(failed_run),
        created_at: workflow.created_at&.iso8601,
        started_at: workflow.started_at&.iso8601,
        finished_at: workflow.finished_at&.iso8601
      }
    end

    def failed_run_payload(run)
      return nil unless run

      {
        id: run.id,
        step_kind: run.step&.kind,
        diagnostic: diagnostic_payload(run),
        failure_classification: run.run_failure_classification&.classification,
        recent_log: recent_log(run)
      }
    end

    def queued_stale_behind_terminal?(queued, terminal)
      queued.any? do |queued_workflow|
        terminal.any? { |terminal_workflow| terminal_workflow.created_at > queued_workflow.created_at }
      end
    end

    def runs_payload
      runs = job.runs.includes(:run_diagnostic, :run_failure_classification, :job_logs, step: :workflow)
                .order(:created_at)
                .to_a
      active = runs.select { |run| run.state.in?(%w[queued running]) }
      {
        latest: run_payload(runs.last),
        active: active.map { |run| run_payload(run) },
        failed: runs.select(&:failed?).map { |run| run_payload(run) },
        heartbeat: active.map { |run| heartbeat_payload(run) }
      }
    end

    def run_payload(run)
      return nil unless run

      {
        id: run.id,
        workflow_id: run.workflow_id,
        step_kind: run.step&.kind,
        state: run.state,
        trigger_kind: run.trigger_kind,
        started_at: run.started_at&.iso8601,
        last_heartbeat_at: run.last_heartbeat_at&.iso8601,
        finished_at: run.finished_at&.iso8601,
        diagnostic: diagnostic_payload(run),
        failure_classification: run.run_failure_classification&.classification,
        recent_log: recent_log(run)
      }
    end

    def heartbeat_payload(run)
      last_signal = run.last_heartbeat_at || run.started_at
      {
        run_id: run.id,
        state: run.state,
        last_signal_at: last_signal&.iso8601,
        silent_for_seconds: last_signal ? (Time.current - last_signal).to_i : nil,
        stale_for_admin: last_signal.present? && last_signal < Run::STALE_HEARTBEAT_THRESHOLD.ago,
        past_reaper_threshold: last_signal.present? && last_signal < Run::STALE_HEARTBEAT_THRESHOLD.ago
      }
    end

    def diagnostic_payload(run)
      diagnostic = run.run_diagnostic
      return nil unless diagnostic

      {
        error_class: diagnostic.error_class,
        error_message: diagnostic.error_message
      }
    end

    def dependencies_payload
      direct = job.dependencies.includes(:depends_on_epic, depends_on_job: [ :repository, :dependencies, :parent_job ]).order(:id).to_a
      unsatisfied = direct.reject(&:dependency_succeeded?)
      {
        overridden: job.dependencies_overridden_at.present?,
        pending: direct.select(&:pending?).map { |dependency| dependency_payload(dependency) },
        unsatisfied: unsatisfied.map { |dependency| dependency_payload(dependency) },
        multiple_leaf_dependencies: leaf_dependency_payloads(unsatisfied),
        redundant_transitive_dependencies: redundant_transitive_dependency_payloads(direct),
        stack_resolution: stack_resolution_payload,
        selected_stack_parent: selected_stack_parent_payload,
        effective_base_branch: job.effective_base_branch,
        pr_base_mismatch: pr_base_mismatch_payload
      }
    end

    def dependency_payload(dependency)
      if dependency.pending?
        {
          dependency_id: dependency.id,
          source: dependency.source,
          pending: true,
          unresolved_ref: dependency.unresolved_slug,
          unresolved_ref_kind: dependency.pending_reference_kind,
          unresolved_ref_state: dependency.pending_reference_state
        }
      elsif dependency.depends_on_epic
        {
          dependency_id: dependency.id,
          source: dependency.source,
          target_type: "epic",
          epic_id: dependency.depends_on_epic_id,
          state: dependency.depends_on_epic.state,
          satisfied: dependency.dependency_succeeded?
        }
      else
        target = dependency.depends_on_job
        {
          dependency_id: dependency.id,
          source: dependency.source,
          target_type: "job",
          job_id: target.id,
          slug: target.slug,
          state: target.state,
          closure_reason: target.closure_reason,
          branch_name: target.branch_name,
          pr_number: target.pr_number || target.external_pr_number,
          satisfied: dependency.dependency_succeeded?
        }
      end
    end

    def leaf_dependency_payloads(unsatisfied)
      leaves = unsatisfied.flat_map { |dependency| unsatisfied_leaf_blockers(dependency) }
      leaves.uniq { |leaf| leaf.fetch(:key) }.map { |leaf| leaf.except(:key) }
    end

    def unsatisfied_leaf_blockers(dependency, seen = Set.new)
      if dependency.pending?
        return [ {
          key: "dependency:#{dependency.id}",
          dependency_id: dependency.id,
          pending: true,
          unresolved_ref: dependency.unresolved_slug,
          unresolved_ref_kind: dependency.pending_reference_kind,
          unresolved_ref_state: dependency.pending_reference_state
        } ]
      end
      return [ { key: "epic:#{dependency.depends_on_epic_id}", epic_id: dependency.depends_on_epic_id, target_type: "epic", state: dependency.depends_on_epic&.state } ] if dependency.depends_on_epic_id.present?

      target = dependency.depends_on_job
      return [] unless target
      return [] if seen.include?(target.id)

      seen << target.id
      blockers = target.dependencies.includes(:depends_on_epic, :depends_on_job).reject(&:dependency_succeeded?)
      return [ { key: "job:#{target.id}", job_id: target.id, slug: target.slug, state: target.state, closure_reason: target.closure_reason } ] if blockers.empty?

      blockers.flat_map { |blocker| unsatisfied_leaf_blockers(blocker, seen) }
    end

    def redundant_transitive_dependency_payloads(dependencies)
      direct_job_ids = dependencies.map(&:depends_on_job_id).compact
      dependencies.filter_map do |dependency|
        target = dependency.depends_on_job
        next unless target

        via = (direct_job_ids - [ target.id ]).find { |other_id| reaches_dependency?(other_id, target.id, Set.new) }
        next unless via

        {
          dependency_id: dependency.id,
          redundant_job_id: target.id,
          redundant_slug: target.slug,
          reachable_through_job_id: via
        }
      end
    end

    def reaches_dependency?(current_id, target_id, seen)
      return true if current_id == target_id
      return false if seen.include?(current_id)

      seen << current_id
      JobDependency.resolved.where(job_id: current_id).pluck(:depends_on_job_id).any? do |next_id|
        reaches_dependency?(next_id, target_id, seen)
      end
    end

    def selected_stack_parent_payload
      parent = selected_stack_parent
      return nil unless parent

      {
        job_id: parent.id,
        slug: parent.slug,
        branch_name: parent.branch_name,
        state: parent.state,
        pr_number: parent.pr_number || parent.external_pr_number
      }
    end

    def selected_stack_parent
      stack_resolution.parent
    end

    def stack_resolution_payload
      resolution = stack_resolution
      {
        ready: resolution.ready?,
        reason: resolution.reason,
        blocker: resolution.blocker
      }.compact
    end

    def stack_resolution
      @stack_resolution ||= JobStackResolver.new(job).resolve!(apply: false)
    end

    def pr_base_mismatch_payload
      pr_number = job.pr_number || job.external_pr_number
      return { checked: false, reason: "job has no pull request" } if pr_number.blank?

      pr = github_client.pull_request(job.repository.slug, pr_number)
      actual = pr.base&.ref
      effective = job.effective_base_branch
      {
        checked: true,
        pr_number: pr_number,
        pr_base_ref: actual,
        effective_base_branch: effective,
        mismatch: actual.present? && effective.present? && actual != effective
      }
    rescue StandardError => e
      { checked: false, reason: "#{e.class}: #{e.message}" }
    end

    def landing_payload
      entry = landing_queue_entry
      {
        queue: entry && {
          position: entry.position,
          eligible: entry.eligible?,
          blocked_reason: entry.blocked_reason,
          waiting_for_job_ids: entry.waiting_for_jobs.map(&:id),
          blocker_job_ids: entry.blocker_jobs.map(&:id),
          dependency_edges: entry.dependency_edges
        },
        merge_train: merge_train_payload,
        pr_checks: {
          state: job.pr_checks_state,
          sha: job.pr_checks_sha,
          checked_at: job.pr_checks_checked_at&.iso8601
        },
        commits_behind_base: job.commits_behind_base,
        mergeability: {
          github_state: job.github_mergeable_state,
          github_mergeable: job.github_mergeable,
          local_mergeable: job.local_mergeable,
          local_state: job.local_mergeable_state,
          checked_at: job.mergeability_checked_at&.iso8601,
          head_sha: job.mergeability_head_sha,
          base_sha: job.mergeability_base_sha,
          base_ref: job.mergeability_base_ref
        },
        landing_failure_reason: job.landing_failure_reason,
        no_effective_ci_repair: no_effective_ci_repair?,
        stale_merge_train_validation: LandingFailureHandler.stale_merge_train_base?(job.landing_failure_reason)
      }
    end

    def landing_queue_entry
      return unless job.state.in?(%w[approved landing])

      LandingQueueProcessor.entries(Job.where(id: job.id)).find { |entry| entry.job_id == job.id }
    end

    def merge_train_payload
      return { enabled: AppSetting.merge_train_enabled? } unless job.epic

      train = MergeTrain.where(epic: job.epic).order(created_at: :desc, id: :desc).first
      workflow_scope = Workflow.where(trigger_kind: "merge_train", job_id: job.epic.jobs.select(:id))
      latest_workflow = workflow_scope.order(created_at: :desc, id: :desc).first
      readiness = MergeTrainAssembler.call(job.epic)
      {
        enabled: AppSetting.merge_train_enabled?,
        readiness: {
          ready: readiness.ready?,
          reason: readiness.reason,
          member_job_ids: readiness.job_ids
        },
        dispatcher_blocker: AppSetting.merge_train_enabled? ? MergeTrainDispatcher.blocker_reason(job.epic) : "merge trains are disabled",
        latest_train: train && {
          id: train.id,
          state: train.state,
          failure_reason: train.failure_reason,
          member_job_ids: train.members.order(:position).pluck(:job_id),
          created_at: train.created_at&.iso8601,
          finished_at: train.finished_at&.iso8601
        },
        latest_workflow: workflow_payload(latest_workflow),
        zero_run_failure: latest_workflow&.failed? && latest_workflow.runs.none?
      }
    end

    def empty_reconciliation_payload
      return { checked: false, evidence: [], reason: "job has no branch" } if job.branch_name.blank?

      evidence = []
      parent_branch = selected_stack_parent&.branch_name.presence || job.effective_base_branch
      if parent_branch.present? && parent_branch != job.branch_name
        branch_tip = github_client.branch_head_sha(job.repository.slug, job.branch_name)
        parent_tip = github_client.branch_head_sha(job.repository.slug, parent_branch)
        evidence << {
          kind: "branch_tip_equals_parent_branch",
          branch: job.branch_name,
          parent_branch: parent_branch,
          sha: branch_tip
        } if branch_tip.present? && branch_tip == parent_tip

        if github_client.respond_to?(:commit_tree_sha)
          branch_tree = github_client.commit_tree_sha(job.repository.slug, job.branch_name)
          parent_tree = github_client.commit_tree_sha(job.repository.slug, parent_branch)
          evidence << {
            kind: "head_tree_equals_effective_parent_tree",
            branch: job.branch_name,
            parent_branch: parent_branch,
            tree_sha: branch_tree
          } if branch_tree.present? && branch_tree == parent_tree
        end
      end

      {
        checked: true,
        evidence: evidence,
        recommended_successful_close: evidence.any? ? "no_changes" : nil
      }
    rescue StandardError => e
      { checked: false, evidence: evidence, reason: "#{e.class}: #{e.message}" }
    end

    def recommended_action(payload)
      return action("close_successfully_no_changes", "Branch has no effective changes.", closure_reason: "no_changes") if payload.dig(:empty_reconciliation, :evidence)&.any?
      return action("inspect_logs", "A running Run has a stale heartbeat.", run_id: stale_heartbeat_run_id(payload)) if stale_heartbeat_run_id(payload)
      return action("inspect_logs", "Latest failure evidence points at grader logs.", run_id: grader_failure_run_id(payload)) if grader_failure_run_id(payload)
      if no_effective_ci_repair?
        if rebase_recommended?(payload)
          return action(
            "confirm_rebase",
            "CI repair made no effective change and checks are still failing; update or rebase the PR branch to retrigger checks.",
            pr_number: job.pr_number
          )
        end
        return action("manual_intervention", "CI repair made no effective change and checks are still failing.", pr_number: job.pr_number)
      end
      return action("confirm_rebase", "The Job is behind base or GitHub reports an unclean mergeability state.") if rebase_recommended?(payload)
      return action("inspect_logs", "PR checks are failing.", pr_number: job.pr_number) if job.pr_checks_state == "failing"
      return action("wait", "PR checks are still pending.", pr_number: job.pr_number) if job.pr_checks_state == "pending"
      return action("manual_intervention", "Dependency graph has unresolved, redundant, or multiple leaf blockers.") if dependency_intervention_needed?(payload)
      return action("retry_job", "The latest workflow failed and no narrower repair action was detected.", workflow_id: job.latest_workflow&.id) if job.latest_workflow&.failed? || job.failed?
      return action("wait", "The Job has active queued or running workflow work.") if payload.dig(:workflows, :active).present?

      action("manual_intervention", "No automated next action was inferred.")
    end

    def stale_heartbeat_run_id(payload)
      payload.dig(:runs, :heartbeat)&.find { |heartbeat| heartbeat[:stale_for_admin] }&.fetch(:run_id)
    end

    def grader_failure_run_id(payload)
      failed = payload.dig(:runs, :failed)&.reverse&.find do |run|
        run[:step_kind] == "grader" || run[:recent_log].to_s.include?("grade") || run.dig(:diagnostic, :error_message).to_s.match?(/grader|rspec|test/i)
      end
      failed&.fetch(:id)
    end

    def rebase_recommended?(payload)
      job.commits_behind_base.to_i.positive? ||
        payload.dig(:landing, :mergeability, :github_state).to_s.in?(%w[dirty blocked behind unstable]) ||
        payload.dig(:landing, :mergeability, :local_mergeable) == false
    end

    def dependency_intervention_needed?(payload)
      payload.dig(:dependencies, :pending).present? ||
        payload.dig(:dependencies, :stack_resolution, :reason).present? ||
        payload.dig(:dependencies, :multiple_leaf_dependencies).to_a.size > 1 ||
        payload.dig(:dependencies, :redundant_transitive_dependencies).present? ||
        payload.dig(:dependencies, :pr_base_mismatch, :mismatch)
    end

    def action(kind, reason, **extra)
      { action: kind, reason: reason }.merge(extra)
    end

    def no_effective_ci_repair?
      job.landing_failure_reason.to_s.start_with?(PollPullRequestJob::NO_EFFECTIVE_CI_REPAIR_REASON)
    end

    def human_summary(payload)
      action = payload.fetch(:recommended_action)
      bits = [ "#{job.slug} is #{job.state}" ]
      if (latest = payload.dig(:workflows, :latest))
        bits << "latest workflow WF-#{latest[:id]} is #{latest[:state]} (#{latest[:trigger_kind]})"
      end
      if payload.dig(:workflows, :queued_stale_behind_terminal)
        bits << "a queued workflow is older than a newer terminal workflow"
      end
      bits << action[:reason]
      "#{bits.join('; ')} Recommended action: #{action[:action]}."
    end

    def recent_log(run)
      run.job_logs.order(sequence: :desc).limit(3).pluck(:chunk).reverse.join.truncate(500).presence
    end

    def github_client
      @github_client ||= GithubClient.for(repository: job.repository, user: job.user)
    end
  end
end
