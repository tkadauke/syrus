module App
  class JobDetailPayload
    include Rails.application.routes.url_helpers
    WORKFLOWS_PER_PAGE = App::WorkflowNavigation::PER_PAGE

    def self.build(job:, user:, params: {})
      new(job: job, user: user, params: params).payload
    end

    def self.timeline(job:)
      new(job: job, user: job.user).timeline_payload
    end

    def initialize(job:, user:, params: {})
      @job = job
      @user = user
      @params = params
    end

    def payload
      {
        job: job_json,
        repository: repository_json(@job.repository),
        epic: epic_json(@job.epic),
        pinned: @user.job_pins.exists?(job: @job),
        tags: @job.tags.ordered.map { |tag| tag_json(tag) },
        tag_options: @user.tags.ordered.map { |tag| tag_json(tag) },
        dependencies: @job.dependencies.includes(:created_by_user, depends_on_job: :repository).map { |dependency| dependency_json(dependency) },
        dependents: @job.dependent_links.includes(job: :repository).map { |dependency| dependent_json(dependency) },
        unsatisfied_dependencies: @job.unsatisfied_dependencies.map { |dependency| dependency_json(dependency) },
        dependency_target_options: dependency_target_options,
        attachments: @job.job_attachments.includes(file_attachment: :blob).map { |attachment| attachment_json(attachment) },
        summary: summary_json,
        test_plan: test_plan_json,
        landing_queue_entry: landing_queue_entry_json,
        workflows: workflows_json,
        workflows_pagination: workflows_pagination_json,
        actions: actions_json,
        paths: paths_json
      }
    end

    def timeline_payload
      {
        job_id: @job.id,
        events: Jobs::Timeline.for(@job).map { |event| timeline_event_json(event) }
      }
    end

    private

    def job_json
      {
        id: @job.id,
        kind: @job.kind,
        state: @job.state,
        summary_state: summary_state(@job),
        priority: @job.priority,
        validity: @job.validity,
        triaging_reason: @job.triaging_reason,
        credential_mode: @job.credential_mode,
        agent_provider: @job.agent_provider,
        stack_base: @job.stack_base,
        parent_job_id: @job.parent_job_id,
        effective_base_branch: @job.effective_base_branch,
        issue_number: @job.issue_number,
        issue_url: issue_url,
        issue_title: @job.issue_title,
        title: @job.issue_title,
        repository_slug: @job.repository.slug,
        issue_body: @job.issue_body,
        branch_name: @job.branch_name,
        pr_number: @job.pr_number,
        pr_url: pr_url(@job.pr_number),
        external_pr_number: @job.external_pr_number,
        external_pr_url: pr_url(@job.external_pr_number),
        pr_mergeable: @job.pr_mergeable,
        pr_mergeable_checked_at: iso8601(@job.pr_mergeable_checked_at),
        last_seen_comment_at: iso8601(@job.last_seen_comment_at),
        last_feedback_addressed_at: iso8601(@job.last_feedback_addressed_at),
        last_ci_handled_sha: @job.last_ci_handled_sha,
        closure_reason: @job.closure_reason,
        failure_count: @job.failure_count,
        landing_failure_reason: @job.landing_failure_reason,
        retry_state: ::App::RetryState.for(@job),
        approved_at: iso8601(@job.approved_at),
        approved_via: @job.approved_via,
        approved_by_user_id: @job.approved_by_user_id,
        owner_user_id: @job.owner_user_id,
        owner_user: owner_user_json(@job.owner_user),
        approval_evidence: @job.approval_evidence,
        claimed_at: iso8601(@job.claimed_at),
        claimed_by_user: owner_json(@job.claimed_by_user),
        claimed_by_current_user: @job.claimed_by_user_id == @user.id,
        invalidation_reason: @job.invalidation_reason,
        invalidation_evidence: @job.invalidation_evidence,
        scheduled_task_id: @job.scheduled_task_id,
        epic_id: @job.epic_id,
        total_cost_usd: @job.display_total_cost_usd&.to_f,
        billed_runs_count: @job.billed_runs_count,
        workflows_count: @job.workflows.size,
        runs_count: @job.runs.size,
        any_active_run: @job.any_active_run?,
        prepare_skipped: @job.prepare_skip_reason.present?,
        prepare_skip_reason: @job.prepare_skip_reason,
        created_at: iso8601(@job.created_at),
        updated_at: iso8601(@job.updated_at),
        started_at: iso8601(@job.started_at),
        finished_at: iso8601(@job.finished_at)
      }
    end

    def repository_json(repository)
      {
        id: repository.id,
        slug: repository.slug,
        owner: repository.owner,
        name: repository.name,
        default_branch: repository.default_branch,
        auto_merge_enabled: repository.auto_merge_enabled,
        approval_propagates_to_github: repository.approval_propagates_to_github,
        credential_mode: repository.credential_mode,
        repository_path: repository_path(repository)
      }
    end

    def epic_json(epic)
      return unless epic

      {
        id: epic.id,
        number: epic.number,
        display_number: epic.display_number,
        title: epic.title,
        state: epic.state,
        epic_path: epic_path(epic)
      }
    end

    def tag_json(tag)
      {
        id: tag.id,
        name: tag.name,
        color: tag.color
      }
    end

    def owner_user_json(owner_user)
      return nil unless owner_user

      {
        id: owner_user.id,
        email_address: owner_user.email_address
      }
    end

    def dependency_json(dependency)
      target = dependency.depends_on_job
      {
        id: dependency.id,
        source: dependency.source,
        manual: dependency.manual?,
        pending: dependency.pending?,
        succeeded: dependency.dependency_succeeded?,
        unresolved_slug: dependency.unresolved_slug,
        created_by_user_id: dependency.created_by_user_id,
        depends_on_job: target && dependency_job_json(target)
      }
    end

    def dependent_json(dependency)
      {
        id: dependency.id,
        source: dependency.source,
        job: dependency_job_json(dependency.job)
      }
    end

    def dependency_job_json(job)
      {
        id: job.id,
        kind: job.kind,
        state: job.state,
        summary_state: summary_state(job),
        repository_slug: job.repository.slug,
        issue_number: job.issue_number,
        issue_title: job.issue_title,
        branch_name: job.branch_name,
        pr_number: job.pr_number,
        job_path: job_path(job)
      }
    end

    def dependency_target_options
      jobs = @user.jobs
                  .includes(:repository)
                  .where.not(id: @job.id)
                  .order(created_at: :desc, id: :desc)

      seen_issues = {}
      current_issue_key = @job.issue? && @job.issue_number.present? ? [ @job.repository_id, @job.issue_number ] : nil
      jobs.each_with_object([]) do |job, options|
        if job.issue? && job.issue_number.present?
          issue_key = [ job.repository_id, job.issue_number ]
          next if issue_key == current_issue_key
          next if seen_issues[issue_key]

          seen_issues[issue_key] = true
          options << { label: dependency_target_label(job), value: "issue:#{job.repository_id}:#{job.issue_number}" }
        else
          options << { label: dependency_target_label(job), value: "job:#{job.id}" }
        end
      end
    end

    def dependency_target_label(job)
      if job.issue? && job.issue_number.present?
        title = job.issue_title.to_s.strip
        title = " - #{title}" if title.present?
        "#{job.repository.slug} ##{job.issue_number}#{title} (#{::App::Presentation.job_slug(job)})"
      else
        title = job.issue_title.to_s.strip.presence || job.kind.titleize
        "#{job.repository.slug} #{::App::Presentation.job_slug(job)} - #{title}"
      end
    end

    def attachment_json(attachment)
      file = attachment.file if attachment.file.attached?
      {
        id: attachment.id,
        kind: attachment.kind,
        attachment_type: attachment.attachment_type,
        title: attachment.title,
        filename: attachment.filename,
        content_type: attachment.content_type,
        byte_size: attachment.byte_size,
        google_doc_url: attachment.google_doc_url,
        uploaded_file: attachment.uploaded_file?,
        file_path: file ? rails_blob_path(file, only_path: true) : nil,
        created_at: iso8601(attachment.created_at),
        app_delete_path: "/api/v1/app/jobs/#{@job.id}/attachments/#{attachment.id}"
      }
    end

    def summary_json
      run = @job.runs.select { |candidate| candidate.agent_summary.present? }.last
      return unless run

      {
        run_id: run.id,
        text: run.agent_summary,
        finished_at: iso8601(run.finished_at)
      }
    end

    def test_plan_json
      entry = @job.workflows.to_a.filter_map do |workflow|
        next unless workflow.artifacts.is_a?(Hash)

        plan = workflow.artifacts["test_plan"]
        next unless plan.is_a?(Hash) && plan.present?

        steps = Array(plan["steps"]).map(&:to_s).map(&:strip).reject(&:empty?)
        next if steps.empty?

        [ workflow, plan, steps ]
      end.max_by { |workflow, _plan, _steps| workflow.created_at }
      return unless entry

      workflow, plan, steps = entry

      {
        workflow_id: workflow.id,
        steps: steps,
        notes: plan["notes"].presence
      }
    end

    def landing_queue_entry_json
      entry = LandingQueueProcessor.entries(@user.jobs).find { |candidate| candidate.job_id == @job.id }
      return unless entry

      {
        position: entry.position,
        blocked_reason: entry.blocked_reason,
        waiting_for_jobs: entry.waiting_for_jobs.map { |job| landing_queue_waiting_job_json(job) },
        blocker_jobs: entry.blocker_jobs.map { |job| landing_queue_blocker_job_json(job, entry) },
        dependency_edges: entry.dependency_edges
      }
    end

    def landing_queue_waiting_job_json(job)
      {
        id: job.id,
        label: job.issue_number.present? ? "##{job.issue_number}" : App::Presentation.job_slug(job),
        title: job.issue_title.presence || App::Presentation.job_slug(job),
        job_path: "/jobs/#{job.id}"
      }
    end

    def landing_queue_blocker_job_json(job, entry)
      json = {
        id: job.id,
        title: job.issue_title.presence || App::Presentation.job_slug(job),
        state: job.state,
        pr_number: job.pr_number || job.external_pr_number,
        pr_path: App::Presentation.job_pr_url(job) || App::Presentation.external_pr_url(job)
      }
      if job.epic_id != landing_queue_entry_epic_id(entry)
        json[:epic_id] = job.epic_id
        json[:epic_title] = job.epic&.title
      end
      json
    end

    def landing_queue_entry_epic_id(entry)
      match = entry.landing_unit_key.to_s.match(/\Aepic:(\d+)\z/)
      match ? match[1].to_i : nil
    end

    def workflows_json
      paginated_workflows.map do |workflow|
        {
          id: workflow.id,
          slug: workflow.slug,
          path: App::WorkflowNavigation.path(workflow),
          trigger_kind: workflow.trigger_kind,
          agent_provider: workflow.agent_provider,
          state: workflow.state,
          failure_count: workflow.failure_count,
          artifacts: workflow.artifacts,
          cleaned_up_at: iso8601(workflow.cleaned_up_at),
          retry_available: workflow.retry_available?,
          started_at: iso8601(workflow.started_at),
          finished_at: iso8601(workflow.finished_at),
          created_at: iso8601(workflow.created_at),
          updated_at: iso8601(workflow.updated_at),
          app_retry_step_path: "/api/v1/app/jobs/#{@job.id}/workflows/#{workflow.id}/retry_step",
          app_push_commits_path: "/api/v1/app/jobs/#{@job.id}/workflows/#{workflow.id}/push_commits",
          failure_classification: workflow_failure_classification_json(workflow),
          steps: workflow.steps.order(:position).map { |step| step_json(step, workflow: workflow) }
        }
      end
    end

    def workflows_pagination_json
      total = total_workflows
      first_item = total.zero? ? 0 : ((workflows_page - 1) * WORKFLOWS_PER_PAGE) + 1
      last_item = [ workflows_page * WORKFLOWS_PER_PAGE, total ].min

      {
        page: workflows_page,
        per_page: WORKFLOWS_PER_PAGE,
        total_workflows: total,
        total_pages: total_workflow_pages,
        first_item: first_item,
        last_item: last_item,
        previous_path: workflows_page > 1 ? workflow_page_path(workflows_page - 1) : nil,
        next_path: workflows_page < total_workflow_pages ? workflow_page_path(workflows_page + 1) : nil
      }
    end

    def paginated_workflows
      @paginated_workflows ||= workflows_scope
        .offset((workflows_page - 1) * WORKFLOWS_PER_PAGE)
        .limit(WORKFLOWS_PER_PAGE)
    end

    def workflows_scope
      @job.workflows
          .includes(steps: { runs: [ :claude_session, :run_diagnostic, :run_failure_classification, :run_health_snapshots, :job_logs, :spawned_processes ] })
          .reorder(created_at: :desc, id: :desc)
    end

    def total_workflows
      @total_workflows ||= @job.workflows.count
    end

    def workflows_page
      @workflows_page ||= [ requested_workflows_page, total_workflow_pages ].min
    end

    def requested_workflows_page
      page = @params[:workflows_page].presence || @params["workflows_page"].presence || 1
      [ page.to_i, 1 ].max
    end

    def total_workflow_pages
      @total_workflow_pages ||= [ (total_workflows / WORKFLOWS_PER_PAGE.to_f).ceil, 1 ].max
    end

    def workflow_page_path(page)
      "#{job_path(@job)}?#{ { tab: "workflows", workflows_page: page }.to_query }"
    end

    def step_json(step, workflow:)
      {
        id: step.id,
        kind: step.kind,
        display_name: step_display_name(step),
        display_status: step_display_status(step),
        position: step.position,
        iteration: step.iteration,
        loop_id: step.loop_id,
        state: step.state,
        started_at: iso8601(step.started_at),
        finished_at: iso8601(step.finished_at),
        created_at: iso8601(step.created_at),
        updated_at: iso8601(step.updated_at),
        details: step.details.presence,
        latest: step == workflow.steps.last,
        runs: step.runs.order(:created_at).map { |run| run_json(run, workflow: workflow) }
      }
    end

    def step_display_name(step)
      return step.details["name"].presence || step.details["command"].presence || "grader" if step.kind == "grader"

      Step::Kind.label_for(step.kind)
    end

    def step_display_status(step)
      active_run = step.runs.find { |run| run.state.in?(%w[queued running]) }
      return active_run.state if active_run
      return nil if step.queued? && step.runs.empty?

      step.state
    end

    def run_json(run, workflow:)
      session = run.claude_session
      {
        id: run.id,
        state: run.state,
        trigger_kind: run.trigger_kind,
        agent_provider: run.agent_provider,
        agent_outcome: run.agent_outcome,
        agent_turns: run.agent_turns,
        agent_pr_title: run.agent_pr_title,
        agent_summary: run.agent_summary,
        parent_session_id: run.parent_session_id,
        head_sha: run.head_sha,
        iteration: run.iteration,
        started_at: iso8601(run.started_at),
        last_heartbeat_at: iso8601(run.last_heartbeat_at),
        finished_at: iso8601(run.finished_at),
        created_at: iso8601(run.created_at),
        updated_at: iso8601(run.updated_at),
        cost_usd: run.cost_usd&.to_f,
        input_tokens: run.input_tokens,
        output_tokens: run.output_tokens,
        cache_creation_input_tokens: run.cache_creation_input_tokens,
        cache_read_input_tokens: run.cache_read_input_tokens,
        agent_diff_present: run.agent_diff.present?,
        agent_diff_bytes: run.agent_diff&.bytesize || 0,
        job_log_count: run.job_logs.size,
        rate_limited: run.job_logs.any? { |log| log.kind == "rate_limited" },
        failure_classification: failure_classification_json(run.run_failure_classification),
        run_diagnostic: run_diagnostic_json(run.run_diagnostic),
        health_snapshots: run.run_health_snapshots.ordered.map { |snapshot| health_snapshot_json(snapshot) },
        agent_session: agent_session_json(session),
        can_stop: run.may_cancel?,
        can_diagnose: run.queued? || run.running?,
        can_resume: %w[failed cancelled].include?(run.state) && session.present?,
        app_artifacts_path: "/api/v1/app/jobs/#{@job.id}/runs/#{run.id}/artifacts",
        app_stop_path: "/api/v1/app/jobs/#{@job.id}/runs/#{run.id}/stop",
        app_diagnose_path: "/api/v1/app/jobs/#{@job.id}/runs/#{run.id}/diagnose",
        app_resume_path: "/api/v1/app/jobs/#{@job.id}/resume",
        app_grade_log_path: app_grade_log_path(run, workflow: workflow)
      }
    end

    def workflow_failure_classification_json(workflow)
      run = workflow.steps
                    .flat_map { |step| step.runs.select(&:failed?) }
                    .sort_by { |candidate| candidate.finished_at || candidate.updated_at || candidate.created_at }
                    .last
      failure_classification_json(run&.run_failure_classification)
    end

    def failure_classification_json(classification)
      return unless classification

      payload = {
        id: classification.id,
        classification: classification.classification,
        confidence: classification.confidence&.to_f,
        retryable: classification.retryable,
        reason: classification.reason,
        diagnostic_summary: classification.diagnostic_summary,
        classified_at: iso8601(classification.classified_at)
      }
      payload[:classifier_inputs] = classification.classifier_inputs if @user.admin?
      payload
    end

    def run_diagnostic_json(diagnostic)
      return unless diagnostic

      base = {
        id: diagnostic.id,
        present: true,
        created_at: iso8601(diagnostic.created_at)
      }
      return base unless @user.admin?

      base.merge(
        error_class: diagnostic.error_class,
        error_message: diagnostic.error_message,
        error_backtrace: diagnostic.error_backtrace,
        repo_snapshot: diagnostic.repo_snapshot,
        git_snapshot: diagnostic.git_snapshot,
        environment_snapshot: diagnostic.environment_snapshot
      )
    end

    def health_snapshot_json(snapshot)
      {
        id: snapshot.id,
        health_status: snapshot.health_status,
        hint: snapshot.hint,
        run_state: snapshot.run_state,
        heartbeat_age_seconds: snapshot.heartbeat_age_seconds,
        last_log_at: iso8601(snapshot.last_log_at),
        log_count: snapshot.log_count,
        agent_turns: snapshot.agent_turns,
        agent_diff_bytes: snapshot.agent_diff_bytes,
        head_sha: snapshot.head_sha,
        sq_job_state: snapshot.sq_job_state,
        worktree_exists: snapshot.worktree_exists,
        claude_process_running: snapshot.claude_process_running,
        branch_on_origin: snapshot.branch_on_origin,
        mcp_sidecar_alive: snapshot.mcp_sidecar_alive,
        last_log_preview: snapshot.last_log_preview,
        worktree_git_status: snapshot.worktree_git_status,
        worktree_recent_commits: snapshot.worktree_recent_commits,
        sq_error_class: snapshot.sq_error_class,
        sq_error_message: snapshot.sq_error_message,
        sq_error_backtrace: snapshot.sq_error_backtrace,
        claude_process_info: snapshot.claude_process_info,
        created_at: iso8601(snapshot.created_at)
      }
    end

    def agent_session_json(session)
      return unless session

      {
        session_id: session.session_id,
        provider: session.provider,
        transcript_pruned: session.transcript_jsonl.nil?,
        transcript_bytes: session.transcript_jsonl&.bytesize,
        transcript_lines: session.transcript_jsonl&.count("\n")
      }
    end

    def app_grade_log_path(run, workflow:)
      step = run.step
      return unless step&.kind.in?(%w[grade grader])

      name = step.details.is_a?(Hash) ? step.details["name"] : nil
      return if name.blank?

      query = { name: name, workflow_id: workflow.id }.compact.to_query
      path = "/api/v1/app/jobs/#{@job.id}/runs/#{run.id}/grade_log"
      query.present? ? "#{path}?#{query}" : path
    end

    def actions_json
      latest_workflow = @job.latest_workflow
      {
        can_start: @job.direct? && @job.open? && @job.runs.empty?,
        can_poll_feedback: @job.open? && @job.pr_number.present?,
        can_rebase: (@job.pr_number.present? || @job.external_pr_number.present?) && !RebaseWorkflowSelector.active_for_stack?(@job),
        can_check_mergeability: @job.pr_number.present? || @job.external_pr_number.present?,
        can_retry: @job.open? && !@job.any_active_run?,
        can_retry_from_failed_step: latest_workflow&.retry_available? || false,
        can_restart: !@job.any_active_run?,
        can_cancel: @job.open?,
        can_approve: @job.may_approve?,
        can_unapprove: @job.may_unapprove?,
        can_reopen: @job.closed?,
        can_mark_valid: @job.validity_duplicate? || @job.validity_already_implemented?,
        can_claim: @job.claimed_by_user_id != @user.id,
        can_unclaim: @job.claimed_by_user_id == @user.id,
        can_override_dependencies: @user.admin?,
        can_view_timeline: @user.admin?,
        feedback_agent_options: @job.alternate_configured_agent_providers,
        rebase_agent_options: @job.alternate_configured_agent_providers,
        retry_agent_options: @job.retry_with_agent_providers
      }
    end

    def paths_json
      {
        job_path: job_path(@job),
        source_path: source_job_path(@job),
        app_detail_path: "/api/v1/app/jobs/#{@job.id}",
        app_source_path: "/api/v1/app/jobs/#{@job.id}/source",
        app_timeline_path: "/api/v1/app/jobs/#{@job.id}/timeline",
        app_start_path: "/api/v1/app/jobs/#{@job.id}/start",
        app_run_again_path: "/api/v1/app/jobs/#{@job.id}/run_again",
        app_restart_path: "/api/v1/app/jobs/#{@job.id}/restart",
        app_cancel_path: "/api/v1/app/jobs/#{@job.id}/cancel",
        app_approve_path: "/api/v1/app/jobs/#{@job.id}/approve",
        app_unapprove_path: "/api/v1/app/jobs/#{@job.id}/unapprove",
        app_reopen_path: "/api/v1/app/jobs/#{@job.id}/reopen",
        app_poll_feedback_path: "/api/v1/app/jobs/#{@job.id}/poll_feedback",
        app_rebase_path: "/api/v1/app/jobs/#{@job.id}/rebase",
        app_check_mergeability_path: "/api/v1/app/jobs/#{@job.id}/check_mergeability",
        app_resume_path: "/api/v1/app/jobs/#{@job.id}/resume",
        app_tags_path: "/api/v1/app/jobs/#{@job.id}/tags",
        app_claim_path: "/api/v1/app/jobs/#{@job.id}/claim",
        app_dependencies_path: "/api/v1/app/jobs/#{@job.id}/dependencies",
        app_dependency_override_path: "/api/v1/app/jobs/#{@job.id}/dependencies/override",
        app_stack_base_path: "/api/v1/app/jobs/#{@job.id}/stack_base",
        app_mark_valid_path: "/api/v1/app/jobs/#{@job.id}/mark_valid",
        app_attachments_path: "/api/v1/app/jobs/#{@job.id}/attachments",
        app_pin_path: "/api/v1/app/jobs/#{@job.id}/pin"
      }
    end

    def timeline_event_json(event)
      workflow = timeline_workflow(event.ref)
      {
        at: iso8601(event.at),
        kind: event.kind.to_s,
        source: event.source,
        transition_source: event.transition_source,
        title: event.title,
        detail: event.detail,
        ref: event.ref,
        ref_label: timeline_ref_label(event.ref, workflow: workflow),
        workflow_path: workflow ? App::WorkflowNavigation.path(workflow) : nil
      }
    end

    def timeline_workflow(ref)
      return unless ref.is_a?(Hash)

      workflow_id = ref[:workflow_id] || ref["workflow_id"]
      return unless workflow_id

      @timeline_workflows ||= @job.workflows.index_by(&:id)
      @timeline_workflows[workflow_id.to_i]
    end

    def timeline_ref_label(ref, workflow:)
      return if ref.blank?
      return workflow.slug if workflow
      return unless ref.is_a?(Hash)

      workflow_id = ref[:workflow_id] || ref["workflow_id"]
      workflow_id ? "WF-#{workflow_id}" : nil
    end

    def owner_json(user)
      return unless user

      {
        id: user.id,
        display_name: user.display_name,
        profile_path: profile_path(user)
      }
    end

    def summary_state(job)
      return "preempted" if job.closure_reason == "preempted"
      return "preempted" if job.closure_reason&.start_with?("external_pr_")

      job.state
    end

    def pr_url(number)
      return if number.blank?

      "https://github.com/#{@job.repository.owner}/#{@job.repository.name}/pull/#{number}"
    end

    def issue_url
      return if @job.issue_number.blank?

      "https://github.com/#{@job.repository.owner}/#{@job.repository.name}/issues/#{@job.issue_number}"
    end

    def iso8601(value)
      value&.iso8601
    end
  end
end
