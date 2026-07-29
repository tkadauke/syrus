module App
  class JobDetailPayload
    include Rails.application.routes.url_helpers
    WORKFLOWS_PER_PAGE = App::WorkflowNavigation::PER_PAGE

    include WorkflowSerializers
    include DependencySerializers
    include LandingQueue

    def self.build(job:, user:, params: {})
      new(job: job, user: user, params: params).payload
    end

    def self.workflows(job:, user:, params: {})
      new(job: job, user: user, params: params).workflows_payload
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
        origin_chat: origin_chat_json,
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
        feedback_history: feedback_history_json,
        pending_feedback: pending_feedback_json,
        landing_queue_entry: landing_queue_entry_json,
        workflows: workflows_json,
        workflows_pagination: workflows_pagination_json,
        feature_flags: feature_flags_json,
        actions: actions_json,
        paths: paths_json
      }
    end

    def workflows_payload
      {
        job: job_json,
        workflows: workflows_json,
        workflows_pagination: workflows_pagination_json,
        feature_flags: feature_flags_json,
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

    def feature_flags_json
      {
        terminal: Feature.terminal_enabled?,
        coding_mode: Feature.coding_mode_enabled?,
        local_mode: Feature.local_mode_enabled?
      }
    end

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
        title_pending: @job.title_pending?,
        repository_slug: @job.repository.slug,
        issue_body: @job.issue_body,
        branch_name: @job.branch_name,
        pr_number: @job.pr_number,
        pr_url: pr_url(@job.pr_number),
        external_pr_number: @job.external_pr_number,
        external_pr_url: pr_url(@job.external_pr_number),
        pr_mergeable: @job.pr_mergeable,
        pr_mergeable_checked_at: iso8601(@job.pr_mergeable_checked_at),
        commits_behind_base: @job.commits_behind_base,
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
        job_approvals: @job.job_approvals.includes(:user).map { |a| job_approval_json(a) },
        approval_status: approval_status_json,
        claimed_at: iso8601(@job.claimed_at),
        claimed_by_user: owner_json(@job.claimed_by_user),
        claimed_by_current_user: @job.claimed_by_user_id == @user.id,
        invalidation_reason: @job.invalidation_reason,
        invalidation_evidence: @job.invalidation_evidence,
        scheduled_task_id: @job.scheduled_task_id,
        scheduled_task: scheduled_task_json(@job.scheduled_task),
        epic_id: @job.epic_id,
        total_cost_usd: @job.display_total_cost_usd&.to_f,
        billed_runs_count: @job.billed_runs_count,
        source_chat: App::JobSourceChat.for(@job),
        workflows_count: @job.workflows.size,
        runs_count: @job.runs.size,
        any_active_run: @job.any_active_run?,
        prepare_skipped: @job.prepare_skip_reason.present?,
        prepare_skip_reason: @job.prepare_skip_reason,
        created_at: iso8601(@job.created_at),
        updated_at: iso8601(@job.updated_at),
        started_at: iso8601(@job.started_at),
        finished_at: iso8601(@job.finished_at),
        needs_attention: @job.needs_attention?,
        needs_attention_reason: @job.needs_attention_reason,
        needs_attention_since: iso8601(@job.needs_attention_since),
        grace_period_expires_at: iso8601(@job.grace_period_expires_at)
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
        review_policy: repository.review_policy,
        feedback_policy: repository.feedback_policy,
        credential_mode: repository.credential_mode,
        main_health: repository.main_health,
        landing_paused: repository.landing_paused?,
        repository_path: repository_path(repository)
      }
    end

    def epic_json(epic)
      return unless epic

      {
        id: epic.id,
        number: epic.number,
        display_number: epic.slug,
        title: epic.title,
        state: epic.state,
        epic_path: epic_path(epic)
      }
    end

    def scheduled_task_json(task)
      return unless task

      {
        id: task.id,
        name: task.name,
        scheduled_task_path: scheduled_task_path(task)
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

    def job_approval_json(approval)
      {
        id: approval.id,
        user_id: approval.user_id,
        user_email: approval.user.email_address,
        approved_at: iso8601(approval.approved_at)
      }
    end

    def approval_status_json
      policy_name = @job.repository.review_policy
      policy_obj = ReviewPolicies.for(policy_name).new(@job)
      approvals = @job.job_approvals.includes(:user)

      {
        policy: policy_name,
        satisfied: policy_obj.satisfied?,
        pending_description: policy_obj.pending_description,
        approvals_count: approvals.size
      }
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
        next unless workflow.succeeded?
        next unless %w[initial retry].include?(workflow.trigger_kind)
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

    def origin_chat_json
      proposal = ChatProposal.where(job_id: @job.id).first
      proposal ||= ChatProposal.where(epic_id: @job.epic_id).first if @job.epic_id
      return unless proposal

      message = ChatMessage.where(proposal_id: proposal.id).first
      return unless message

      {
        chat_session_id: proposal.chat_session_id,
        message_id: message.id
      }
    end

    def pending_feedback_json
      return [] unless @job.repository.feedback_policy_confirm?

      @job.pr_review_comments
          .actionable_comments
          .unactioned
          .where.not(attributed_to: "job_owner")
          .order(:comment_created_at, :id)
          .map do |comment|
        {
          id: comment.id,
          github_handle: comment.github_handle,
          attributed_to: comment.attributed_to,
          pr_type: comment.pr_type,
          comment_kind: comment.comment_kind,
          body: comment.body,
          comment_created_at: iso8601(comment.comment_created_at)
        }
      end
    end

    def feedback_history_json
      @job.workflows
        .select { |workflow| Workflow::TriggerKind.feedback_kind_for(workflow.trigger_kind) }
        .sort_by { |workflow| workflow.created_at || Time.at(0) }
        .filter_map do |workflow|
          feedback_entry_for(workflow)
        end
    end

    def feedback_entry_for(workflow)
      case Workflow::TriggerKind.feedback_kind_for(workflow.trigger_kind)
      when :chat_feedback
        body = workflow.artifacts&.dig("chat_feedback")
        return unless body.present?

        source = workflow.artifacts&.dig("feedback_source")
        { kind: "chat_feedback", body: body, created_at: iso8601(workflow.created_at), state: workflow.state, feedback_source: source }
      when :pr_comment
        comments = Array(workflow.artifacts&.dig("pr_comments"))
        return if comments.empty?

        body = comments.map do |comment|
          author = comment["author"].present? ? "@#{comment["author"]}: " : ""
          "#{author}#{comment["body"]}"
        end.join("\n\n")

        { kind: "pr_comment", body: body, created_at: iso8601(workflow.created_at), state: workflow.state, feedback_source: nil }
      end
    end

    def actions_json
      retry_actions = ::App::JobRetryActions.for(@job)
      {
        can_start: @job.direct? && @job.open? && @job.runs.empty?,
        can_poll_feedback: @job.open? && @job.pr_number.present?,
        can_rebase: (@job.pr_number.present? || @job.external_pr_number.present?) && !RebaseWorkflowSelector.active_for_stack?(@job),
        can_check_mergeability: @job.pr_number.present? || @job.external_pr_number.present?,
        can_retry: retry_actions[:implementation].present?,
        can_retry_from_failed_step: retry_actions[:failed_step].present?,
        retry_failed_step_action: retry_actions[:failed_step],
        retry_implementation_action: retry_actions[:implementation],
        can_restart: !@job.any_active_run? && !@job.cron? && !@job.no_change_needed?,
        can_cancel: @job.open?,
        can_approve: @job.can_add_job_approval?(@user),
        can_unapprove: @job.may_unapprove?,
        can_reopen: @job.closed? && !@job.infrastructure?,
        can_mark_valid: @job.validity_duplicate? || @job.validity_already_implemented?,
        can_open_in_local_mode: Feature.local_mode_enabled? && (@job.implemented? || @job.approved?) && @job.linked_chat_id.nil?,
        can_cancel_local_mode: Feature.local_mode_enabled? && @job.coding?,
        linked_chat_id: @job.linked_chat_id,
        can_claim: @job.claimed_by_user_id != @user.id,
        can_unclaim: @job.claimed_by_user_id == @user.id,
        can_override_dependencies: @user.admin?,
        can_view_timeline: @user.admin?,
        can_manage_tags: @job.user_id == @user.id,
        can_open_in_coding_mode: Feature.coding_mode_enabled? &&
          (@job.implemented? || @job.approved?) &&
          @job.branch_name.present?,
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
        app_pin_path: "/api/v1/app/jobs/#{@job.id}/pin",
        app_pending_feedback_path: "/api/v1/app/jobs/#{@job.id}/pending_feedback",
        app_open_in_coding_mode_path: "/api/v1/app/jobs/#{@job.id}/open_in_coding_mode",
        app_open_in_local_mode_path: "/api/v1/app/jobs/#{@job.id}/open_in_local_mode",
        app_cancel_local_mode_path: "/api/v1/app/jobs/#{@job.id}/cancel_local_mode",
        app_priority_path: "/api/v1/app/jobs/#{@job.id}/priority"
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
