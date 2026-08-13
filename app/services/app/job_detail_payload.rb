require "shellwords"

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

    def self.build_dependency_options(job:, user:)
      new(job: job, user: user).dependency_options_payload
    end

    def initialize(job:, user:, params: {})
      @job = job
      @user = user
      @params = params
    end

    def payload
      PerformanceLogging.phase("job_detail_payload", job_id: @job.id) do
        result = {
          job: PerformanceLogging.phase("job_detail.job", job_id: @job.id) { job_json },
          repository: PerformanceLogging.phase("job_detail.repository", job_id: @job.id) { repository_json(@job.repository) },
          epic: PerformanceLogging.phase("job_detail.epic", job_id: @job.id) { epic_json(@job.epic) },
          merge_train_status: PerformanceLogging.phase("job_detail.merge_train_status", job_id: @job.id) { App::MergeTrainStatus.for_job(@job) },
          origin_chat: PerformanceLogging.phase("job_detail.origin_chat", job_id: @job.id) { origin_chat_json },
          pinned: PerformanceLogging.phase("job_detail.pinned", job_id: @job.id) { @user.job_pins.exists?(job: @job) },
          tags: PerformanceLogging.phase("job_detail.tags", job_id: @job.id) { @job.tags.ordered.map { |tag| tag_json(tag) } },
          tag_options: PerformanceLogging.phase("job_detail.tag_options", job_id: @job.id) { @user.tags.ordered.map { |tag| tag_json(tag) } },
          dependencies: PerformanceLogging.phase("job_detail.dependencies", job_id: @job.id) { @job.dependencies.includes(:created_by_user, depends_on_job: :repository, depends_on_epic: :repository).map { |dependency| dependency_json(dependency) } },
          dependents: PerformanceLogging.phase("job_detail.dependents", job_id: @job.id) { @job.dependent_links.includes(job: :repository).map { |dependency| dependent_json(dependency) } },
          unsatisfied_dependencies: PerformanceLogging.phase("job_detail.unsatisfied_dependencies", job_id: @job.id) { @job.unsatisfied_dependencies.map { |dependency| dependency_json(dependency) } },
          dependency_target_options: [],
          epic_dependency_target_options: [],
          attachments: PerformanceLogging.phase("job_detail.attachments", job_id: @job.id) { @job.job_attachments.includes(file_attachment: :blob).map { |attachment| attachment_json(attachment) } },
          typed_artifacts: PerformanceLogging.phase("job_detail.typed_artifacts", job_id: @job.id) { typed_artifacts_json },
          summary: PerformanceLogging.phase("job_detail.summary", job_id: @job.id) { summary_json },
          test_plan: PerformanceLogging.phase("job_detail.test_plan", job_id: @job.id) { test_plan_json },
          has_test_results: PerformanceLogging.phase("job_detail.has_test_results", job_id: @job.id) { has_test_results? },
          feedback_history: PerformanceLogging.phase("job_detail.feedback_history", job_id: @job.id) { feedback_history_json },
          pending_feedback: PerformanceLogging.phase("job_detail.pending_feedback", job_id: @job.id) { pending_feedback_json },
          landing_queue_entry: PerformanceLogging.phase("job_detail.landing_queue_entry", job_id: @job.id) { landing_queue_entry_json },
          preview: PerformanceLogging.phase("job_detail.preview", job_id: @job.id) { preview_env_json },
          workflows: PerformanceLogging.phase("job_detail.workflows", job_id: @job.id, page: workflows_page) { workflows_json },
          workflows_pagination: PerformanceLogging.phase("job_detail.workflows_pagination", job_id: @job.id) { workflows_pagination_json },
          feature_flags: feature_flags_json,
          actions: PerformanceLogging.phase("job_detail.actions", job_id: @job.id) { actions_json },
          paths: paths_json
        }
        stages = @job.landed_sha.present? ? PerformanceLogging.phase("job_detail.deployment_stages", job_id: @job.id) { deployment_stages_payload } : nil
        result[:deployment_stages] = stages if @job.landed_sha.present? && stages
        result
      end
    end

    def workflows_payload
      PerformanceLogging.phase("job_workflows_payload", job_id: @job.id, page: workflows_page) do
        {
          job: PerformanceLogging.phase("job_workflows.job", job_id: @job.id) { job_json },
          workflows: PerformanceLogging.phase("job_workflows.workflows", job_id: @job.id, page: workflows_page) { workflows_json },
          workflows_pagination: workflows_pagination_json,
          feature_flags: feature_flags_json,
          actions: PerformanceLogging.phase("job_workflows.actions", job_id: @job.id) { actions_json },
          paths: paths_json
        }
      end
    end

    def timeline_payload
      PerformanceLogging.phase("job_timeline_payload", job_id: @job.id) do
        {
          job_id: @job.id,
          events: PerformanceLogging.phase("job_timeline.events", job_id: @job.id) { Jobs::Timeline.for(@job).map { |event| timeline_event_json(event) } }
        }
      end
    end

    def dependency_options_payload
      PerformanceLogging.phase("job_dependency_options_payload", job_id: @job.id) do
        {
          dependency_target_options: PerformanceLogging.phase("job_dependency_options.job_targets", job_id: @job.id) { dependency_target_options },
          epic_dependency_target_options: PerformanceLogging.phase("job_dependency_options.epic_targets", job_id: @job.id) { epic_dependency_target_options }
        }
      end
    end

    private

    def feature_flags_json
      {
        terminal: Feature.terminal_enabled?,
        coding_mode: Feature.coding_mode_enabled?,
        local_mode: Feature.local_mode_enabled?
      }
    end

    def job_provider_setting_options
      PerformanceLogging.phase("job_detail.job.provider_setting_options", job_id: @job.id) do
        Job::PROVIDER_SETTINGS.map do |setting|
          {
            value: setting,
            label: setting == "default" ? "Default" : App::Presentation.agent_provider_label(setting),
            configured: setting == "default" || PerformanceLogging.phase("job_detail.job.agent_provider_configured", job_id: @job.id, provider: setting) { @user.agent_provider_configured?(setting) }
          }
        end
      end
    end

    def job_json
      workflow_agent_provider = PerformanceLogging.phase("job_detail.job.workflow_agent_provider", job_id: @job.id) { @job.workflow_agent_provider }
      provider_availability = PerformanceLogging.phase("job_detail.job.provider_availability", job_id: @job.id, provider: workflow_agent_provider) do
        App::ProviderAvailability.for_user(@user, workflow_agent_provider)
      end
      retry_state = PerformanceLogging.phase("job_detail.job.retry_state", job_id: @job.id) { ::App::RetryState.for(@job) }
      approval_status = PerformanceLogging.phase("job_detail.job.approval_status", job_id: @job.id) { approval_status_json }
      worker_health_correlation = PerformanceLogging.phase("job_detail.job.worker_health_correlation", job_id: @job.id) { worker_health_job_correlation_json }
      source_chat = PerformanceLogging.phase("job_detail.job.source_chat", job_id: @job.id) { App::JobSourceChat.for(@job) }
      workflows_count = PerformanceLogging.phase("job_detail.job.workflows_count", job_id: @job.id) { @job.workflows.size }
      runs_count = PerformanceLogging.phase("job_detail.job.runs_count", job_id: @job.id) { @job.runs.size }
      any_active_run = PerformanceLogging.phase("job_detail.job.any_active_run", job_id: @job.id) { @job.any_active_run? }
      prepare_skip_reason = PerformanceLogging.phase("job_detail.job.prepare_skip_reason", job_id: @job.id) { @job.prepare_skip_reason }
      start_blocked = PerformanceLogging.phase("job_detail.job.start_blocked", job_id: @job.id) do
        {
          reason: job_start_blocked_reason,
          at: job_start_blocked_at,
          next_check_at: job_start_blocked_next_check_at,
          count: job_start_blocked_count,
          details: job_start_blocked_details,
          breakdown: job_start_blocked_breakdown
        }
      end

      {
        id: @job.id,
        kind: @job.kind,
        state: @job.state,
        summary_state: summary_state(@job),
        priority: @job.priority,
        validity: @job.validity,
        triaging_reason: @job.triaging_reason,
        credential_mode: @job.credential_mode,
        agent_provider: workflow_agent_provider,
        job_provider_setting: @job.job_provider_setting,
        job_provider_setting_options: job_provider_setting_options,
        provider_availability: provider_availability,
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
        no_pr_reason: no_pr_reason_json,
        pr_mergeable: @job.pr_mergeable,
        pr_mergeable_checked_at: iso8601(@job.pr_mergeable_checked_at),
        commits_behind_base: @job.commits_behind_base,
        last_seen_comment_at: iso8601(@job.last_seen_comment_at),
        last_feedback_addressed_at: iso8601(@job.last_feedback_addressed_at),
        last_ci_handled_sha: @job.last_ci_handled_sha,
        closure_reason: @job.closure_reason,
        runaway_protection: @job.runaway_protection,
        failure_count: @job.failure_count,
        landing_failure_reason: @job.landing_failure_reason,
        retry_state: retry_state,
        approved_at: iso8601(@job.approved_at),
        approved_via: @job.approved_via,
        approved_by_user_id: @job.approved_by_user_id,
        owner_user_id: @job.owner_user_id,
        owner_user: owner_user_json(@job.owner_user),
        approval_evidence: @job.approval_evidence,
        job_approvals: @job.job_approvals.includes(:user).map { |a| job_approval_json(a) },
        approval_status: approval_status,
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
        worker_health_correlation: worker_health_correlation,
        source_chat: source_chat,
        workflows_count: workflows_count,
        runs_count: runs_count,
        any_active_run: any_active_run,
        prepare_skipped: prepare_skip_reason.present?,
        prepare_skip_reason: prepare_skip_reason,
        created_at: iso8601(@job.created_at),
        updated_at: iso8601(@job.updated_at),
        started_at: iso8601(@job.started_at),
        finished_at: iso8601(@job.finished_at),
        needs_attention: @job.needs_attention?,
        needs_attention_reason: @job.needs_attention_reason,
        needs_attention_since: iso8601(@job.needs_attention_since),
        grace_period_expires_at: iso8601(@job.grace_period_expires_at),
        main_branch_repair: @job.main_branch_repair?,
        start_blocked_reason: start_blocked.fetch(:reason),
        start_blocked_at: start_blocked.fetch(:at),
        start_blocked_next_check_at: start_blocked.fetch(:next_check_at),
        start_blocked_count: start_blocked.fetch(:count),
        start_blocked_details: start_blocked.fetch(:details),
        start_blocked_breakdown: start_blocked.fetch(:breakdown)
      }.merge(deployment_stages_json)
    end

    def worker_health_job_correlation_json
      WorkerHealthRunCorrelation.for_job(@job)
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

    def deployment_stages_json
      return {} if @job.landed_sha.blank?

      stages = deployment_stages_payload
      return {} unless stages

      { deployment_stages: stages }
    end

    def deployment_stages_payload
      @deployment_stages_payload ||= App::DeploymentStagesPayload.for_job(@job)
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

    def no_pr_reason_json
      @job.workflows
          .select { |workflow| workflow.artifacts.is_a?(Hash) && workflow.artifacts["no_pr_reason"].is_a?(Hash) }
          .max_by(&:created_at)
          &.artifacts
          &.fetch("no_pr_reason", nil)
    end

    def attachment_json(attachment)
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
        file_path: attachment.file.attached? ? "/api/v1/app/jobs/#{@job.id}/attachments/#{attachment.id}/file" : nil,
        created_at: iso8601(attachment.created_at),
        app_delete_path: "/api/v1/app/jobs/#{@job.id}/attachments/#{attachment.id}"
      }
    end

    def typed_artifacts_json
      renderer_map = Syrus::PluginRegistry
        .providers_for(:artifact_renderer)
        .each_with_object({}) { |klass, hash| hash[klass.artifact_type] = klass.renderer_type.to_s }

      # Collect typed artifacts from all workflows, deduplicating by type and
      # keeping the most recent entry (by workflow created_at) for each type.
      latest_by_type = {}
      @job.workflows
        .sort_by { |wf| wf.created_at || Time.at(0) }
        .each do |wf|
          next unless wf.artifacts.is_a?(Hash)

          Array(wf.artifact("typed_artifacts")).each do |entry|
            next unless entry.is_a?(Hash) && entry["type"].present?

            latest_by_type[entry["type"]] = entry
          end
        end

      latest_by_type.values.map do |entry|
        {
          type: entry["type"],
          title: entry["title"],
          payload: entry["payload"],
          created_at: entry["created_at"],
          renderer_type: renderer_map[entry["type"]]
        }
      end
    end

    def summary_json
      if (entry = latest_canonical_metadata_entry)
        workflow, metadata = entry
        return {
          workflow_id: workflow.id,
          text: metadata["summary"],
          finished_at: iso8601(workflow.finished_at)
        }
      end

      run = @job.runs
                .where.not(agent_summary: [ nil, "" ])
                .order(created_at: :desc, id: :desc)
                .first
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
        next unless workflow.artifacts.is_a?(Hash)

        plan = canonical_test_plan_for(workflow)
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

    def latest_canonical_metadata_entry
      @job.workflows.to_a.filter_map do |workflow|
        next unless workflow.succeeded?

        metadata = workflow.artifact("job_metadata")
        next unless metadata.is_a?(Hash)
        next unless metadata["changed"] == true
        next if metadata["summary"].blank?

        [ workflow, metadata ]
      end.max_by { |workflow, _metadata| [ workflow.finished_at || workflow.created_at, workflow.id ] }
    end

    def canonical_test_plan_for(workflow)
      metadata = workflow.artifact("job_metadata")
      if metadata.is_a?(Hash) && metadata["changed"] == true && metadata["test_plan"].is_a?(Hash)
        return metadata["test_plan"]
      end

      return workflow.artifact("test_plan") if %w[initial retry].include?(workflow.trigger_kind)

      nil
    end

    def has_test_results?
      TestRun.where(run_id: @job.runs.select(:id)).exists?
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
      @job.pr_review_comments
          .actionable_comments
          .where.not(attributed_to: "job_owner")
          .order(:comment_created_at, :id)
          .select { |comment| @job.repository.feedback_policy_confirm? ? comment.pending_for_operator? : comment.retryable_handling? }
          .map do |comment|
        {
          id: comment.id,
          github_handle: comment.github_handle,
          attributed_to: comment.attributed_to,
          pr_type: comment.pr_type,
          comment_kind: comment.comment_kind,
          body: comment.body,
          comment_created_at: iso8601(comment.comment_created_at),
          handling_state: comment.handling_state || "pending",
          handling_workflow_id: comment.handling_workflow_id,
          handling_failed_at: iso8601(comment.handling_failed_at),
          handling_failure_reason: comment.handling_failure_reason,
          retryable: comment.retryable_handling?
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
        can_rebase: (@job.pr_number.present? || @job.external_pr_number.present?) &&
          !RebaseWorkflowSelector.active_for_stack?(@job) &&
          !RebaseWorkflowSelector.active_merge_train_for_stack?(@job),
        can_check_mergeability: @job.pr_number.present? || @job.external_pr_number.present?,
        can_retry_pr_ingestion: @job.open? && @job.external_pr_ingest_blocked? && !@job.workflows.active.exists?,
        can_retry: retry_actions[:implementation].present?,
        can_retry_from_failed_step: retry_actions[:failed_step].present?,
        retry_failed_step_action: retry_actions[:failed_step],
        retry_implementation_action: retry_actions[:implementation],
        can_restart: !@job.any_active_run? && !@job.cron? && !@job.no_change_needed?,
        can_cancel: @job.open?,
        can_approve: @job.can_add_job_approval?(@user) && !simple_epic_child?,
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
        can_view_resource_admission_diagnostics: @user.admin?,
        can_manage_tags: @job.user_id == @user.id,
        can_open_in_coding_mode: Feature.coding_mode_enabled? &&
          (@job.implemented? || @job.approved?) &&
          @job.branch_name.present?,
        can_start_preview: preview_provider_configured? && @job.previewable?,
        feedback_agent_options: @job.alternate_configured_agent_providers,
        rebase_agent_options: @job.alternate_configured_agent_providers,
        retry_agent_options: @job.retry_with_agent_providers
      }
    end

    def simple_epic_child?
      AppSetting.simple? && @job.epic_id.present?
    end

    def paths_json
      {
        job_path: job_path(@job),
        source_path: source_job_path(@job),
        app_detail_path: "/api/v1/app/jobs/#{@job.id}",
        app_source_path: "/api/v1/app/jobs/#{@job.id}/source",
        app_test_results_path: "/api/v1/app/jobs/#{@job.id}/test_results",
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
        app_retry_pr_ingestion_path: "/api/v1/app/jobs/#{@job.id}/retry_pr_ingestion",
        app_check_mergeability_path: "/api/v1/app/jobs/#{@job.id}/check_mergeability",
        app_resume_path: "/api/v1/app/jobs/#{@job.id}/resume",
        app_tags_path: "/api/v1/app/jobs/#{@job.id}/tags",
        app_claim_path: "/api/v1/app/jobs/#{@job.id}/claim",
        app_dependencies_path: "/api/v1/app/jobs/#{@job.id}/dependencies",
        app_dependency_options_path: "/api/v1/app/jobs/#{@job.id}/dependency_options",
        app_dependency_override_path: "/api/v1/app/jobs/#{@job.id}/dependencies/override",
        app_epic_dependencies_path: "/api/v1/app/jobs/#{@job.id}/epic_dependencies",
        app_stack_base_path: "/api/v1/app/jobs/#{@job.id}/stack_base",
        app_mark_valid_path: "/api/v1/app/jobs/#{@job.id}/mark_valid",
        app_attachments_path: "/api/v1/app/jobs/#{@job.id}/attachments",
        app_pin_path: "/api/v1/app/jobs/#{@job.id}/pin",
        app_pending_feedback_path: "/api/v1/app/jobs/#{@job.id}/pending_feedback",
        app_open_in_coding_mode_path: "/api/v1/app/jobs/#{@job.id}/open_in_coding_mode",
        app_open_in_local_mode_path: "/api/v1/app/jobs/#{@job.id}/open_in_local_mode",
        app_cancel_local_mode_path: "/api/v1/app/jobs/#{@job.id}/cancel_local_mode",
        app_priority_path: "/api/v1/app/jobs/#{@job.id}/priority",
        app_provider_setting_path: "/api/v1/app/jobs/#{@job.id}/provider_setting",
        app_preview_path: "/api/v1/app/jobs/#{@job.id}/preview",
        admin_resource_admission_path: admin_resource_admission_path
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

    def job_start_blocked_reason
      workflow_for_start_blocked&.artifact("start_blocked_reason")
    end

    def job_start_blocked_at
      workflow_for_start_blocked&.artifact("start_blocked_at")
    end

    def job_start_blocked_next_check_at
      workflow_for_start_blocked&.artifact("start_blocked_next_check_at")
    end

    def job_start_blocked_count
      workflow_for_start_blocked&.artifact("start_blocked_count")
    end

    def job_start_blocked_details
      workflow_for_start_blocked&.artifact("start_blocked_details")
    end

    def job_start_blocked_breakdown
      return nil unless job_start_blocked_reason == StepDispatcher::ADMISSION_BLOCK_REASON

      details = job_start_blocked_details
      return nil unless details.is_a?(Hash)

      AdmissionDiagnostics::Breakdown.for(details)
    end

    def workflow_for_start_blocked
      @workflow_for_start_blocked ||= @job.workflows
        .where(state: %w[queued running])
        .where("artifacts LIKE ?", '%"start_blocked_reason"%')
        .reorder(created_at: :desc, id: :desc)
        .detect { |wf| wf.artifact("start_blocked_reason").present? }
    end

    def summary_state(job)
      return "preempted" if job.closure_reason == "preempted"
      return "preempted" if job.closure_reason&.start_with?("external_pr_")
      return "paused" if job_apparently_paused?(job)

      job.state
    end

    def job_apparently_paused?(job)
      return false if job.any_active_run?

      workflow = job.latest_workflow
      workflow&.running? && !workflow.landing_workflow? && (
        workflow.artifact("pause_reason").present? ||
          workflow.artifact("start_blocked_reason").present?
      )
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

    def preview_env_json
      envs = @job.preview_environments.to_a
      env = envs.find(&:active?) || envs.max_by(&:created_at)
      return nil unless env

      base_domain = ENV.fetch("SYRUS_PREVIEW_BASE_DOMAIN", "lvh.me")
      {
        id: env.id,
        state: env.state,
        url: env.running? ? env.preview_url(base_domain) : nil,
        expires_at: env.expires_at&.iso8601,
        error_message: env.error_message
      }
    end

    def preview_provider_configured?
      return @preview_provider_configured unless @preview_provider_configured.nil?

      @preview_provider_configured = (
        Syrus::Plugin::PreviewProvider.configured? || syrus_yml_has_preview?
      )
    end

    def syrus_yml_has_preview?
      clone_path = File.join(
        ENV.fetch("SYRUS_DATA_ROOT", File.expand_path("~/.syrus")),
        "clones",
        "#{@job.repository_id}.git"
      )
      return false unless File.directory?(clone_path)

      yml_content = `git --git-dir #{clone_path.shellescape} show HEAD:.syrus.yml 2>/dev/null`
      return false unless $?.success? && yml_content.present?

      SyrusYml.new(yml_content).parse.preview.present?
    rescue StandardError
      false
    end
  end
end
