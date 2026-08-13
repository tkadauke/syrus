module App
  module Presentation
    GITHUB_APP_INSTALL_BASE_URL = "https://github.com/apps".freeze

    module_function

    def agent_provider_label(provider)
      klass = PerformanceLogging.phase("presentation.agent_provider_label.lookup", provider: provider) do
        Syrus::PluginRegistry.providers_for(:agent_provider)
          .find do |p|
            PerformanceLogging.plugin_call(extension_point: :agent_provider, provider: p, operation: :provider_key) do
              p.provider_key == provider.to_s
            end
          end
      end
      klass&.display_name || provider.to_s.titleize
    end

    def job_slug(job_or_id)
      id = job_or_id.respond_to?(:id) ? job_or_id.id : job_or_id
      "JOB-#{id}"
    end

    def epic_slug(epic_or_number)
      number = epic_or_number.respond_to?(:number) ? epic_or_number.number : epic_or_number
      "EPIC-#{number}"
    end

    # Generic install URL (operator picks repos in GitHub's UI). Used by
    # onboarding before any specific repository is selected.
    def github_app_generic_install_url
      return nil unless AppSetting.github_app_registered?

      slug = AppSetting.current.github_app_slug
      return nil if slug.blank?

      "#{GITHUB_APP_INSTALL_BASE_URL}/#{CGI.escape(slug)}/installations/new"
    end

    def github_app_install_url_for(repositories)
      repos = Array(repositories).compact
      return nil unless AppSetting.github_app_registered?
      return nil if AppSetting.current.github_app_slug.blank?
      return nil if repos.empty?

      owner_id = repos.first.github_owner_id
      return nil if owner_id.blank?
      return nil unless repos.all? { |repo| repo.github_owner_id == owner_id && repo.github_repository_id.present? }

      query = [ "target_id=#{CGI.escape(owner_id.to_s)}" ]
      repos.each do |repo|
        query << "repository_ids[]=#{CGI.escape(repo.github_repository_id.to_s)}"
      end

      "#{GITHUB_APP_INSTALL_BASE_URL}/#{CGI.escape(AppSetting.current.github_app_slug)}/installations/new/permissions?#{query.join('&')}"
    end

    def job_summary_state(job)
      return "preempted" if job.closure_reason == "preempted"
      return "preempted" if job.closure_reason&.start_with?("external_pr_")

      job.state
    end

    def workflow_dashboard_state(state, trigger_kind)
      return "postponed" if trigger_kind == "auto_merge" && state == "cancelled"

      state
    end

    def current_step_caption(job)
      workflow = job.workflows.where(state: "running").order(:created_at).last
      return nil unless workflow

      step = workflow.current_step
      return "currently: #{workflow.trigger_kind_humanized}" unless step

      "currently: #{Step::Kind.label_for(step.kind)} (workflow: #{workflow.trigger_kind_humanized})"
    end

    def job_pr_url(job)
      return nil if job.pr_number.blank?

      "https://github.com/#{job.repository.slug}/pull/#{job.pr_number}"
    end

    def external_pr_url(job)
      return nil if job.external_pr_number.blank?

      "https://github.com/#{job.repository.slug}/pull/#{job.external_pr_number}"
    end

    # True when the PR being shown for this Job was not opened by Syrus —
    # either an external_pr-kind Job, or a Syrus-initiated Job whose own PR
    # was preempted by an externally authored one.
    def pr_external?(job)
      job.pr_number.blank? && job.external_pr_number.present?
    end

    def job_issue_url(job)
      return nil if job.issue_number.blank?

      "https://github.com/#{job.repository.slug}/issues/#{job.issue_number}"
    end

    def epic_state_transition_options(epic)
      transitions = []
      transitions << [ "Move to ready", "ready" ] if epic.backlog? && epic.may_auto_ready?
      transitions << [ "Move to backlog", "backlog" ] if epic.ready? && epic.may_move_to_backlog?
      transitions << [ "Start", "in_progress" ] if epic.ready? && epic.may_start?
      transitions << [ "Move back to ready", "ready" ] if epic.in_progress? && epic.may_unstart?
      transitions << [ "Mark as done", "done" ] if epic.in_progress? && (epic.may_auto_complete? || epic.all_jobs_closed?)
      transitions << [ "Archive", "archived" ] if epic.may_archive?
      transitions
    end

    # Single source of truth for pending-action label/detail rendering.
    # Both App::ChatMessagePayload (message-anchored pending actions) and
    # ChatPendingActions (the live/unanchored pending-actions list) must
    # delegate here instead of keeping their own case statements — two
    # independent copies previously drifted out of sync and a chat agent
    # tool (submit_coding_changes) silently rendered a blank label/detail
    # in the live list while working fine once anchored to a message.
    def pending_action_label(action)
      payload = action.payload || {}
      case action.action
      when "cancel_job"
        "Cancel #{job_slug(payload['job_id'])}"
      when "close_job_successfully"
        "Close #{job_slug(payload['job_id'])} as #{payload['closure_reason']}"
      when "retry_job"
        "Retry #{job_slug(payload['job_id'])}"
      when "force_fail_job"
        "Force fail #{job_slug(payload['job_id'])}"
      when "rebase_job"
        "Rebase #{job_slug(payload['job_id'])}"
      when "force_rebase"
        "Force rebase #{job_slug(payload['job_id'])}"
      when "restack_epic"
        "Restack Epic ##{payload['epic_id']}"
      when "reopen_job"
        "Reopen #{job_slug(payload['job_id'])}"
      when "fire_scheduled_task_now"
        "Fire scheduled task ##{payload['scheduled_task_id']}"
      when "create_repo_document"
        "Create document #{payload['title'].to_s.inspect}"
      when "delete_repo_document"
        "Delete document #{payload['title'].to_s.presence || "##{payload['document_id']}"}"
      when "poll_job_feedback"
        "Poll PR feedback for #{job_slug(payload['job_id'])}"
      when "run_visual_review"
        "Run visual review for #{job_slug(payload['job_id'])}"
      when "check_job_mergeability"
        "Check mergeability for #{job_slug(payload['job_id'])}"
      when "force_landing_recheck"
        "Force landing recheck for #{job_slug(payload['job_id'])}"
      when "override_landing_blocker_once"
        "Override #{payload['blocker_key']} once for #{job_slug(payload['job_id'])}"
      when "wake_landing_queue"
        "Wake landing queue"
      when "delegate_issue"
        "Delegate issue ##{payload['issue_number']}"
      when "pause_landing_queue"
        "Pause landing queue"
      when "resume_landing_queue"
        "Resume landing queue"
      when "submit_chat_feedback"
        "Submit feedback on #{job_slug(payload['job_id'])}"
      when "reopen_epic_and_attach_job"
        "Reopen Epic ##{payload['epic_id']} and attach #{job_slug(payload['job_id'])}"
      when "submit_coding_changes"
        payload["title"].presence || action.action_type.to_s.humanize
      when "admin_kill_process"
        "Kill process ##{payload['process_id']}"
      when "admin_reap_stale_runs"
        "Force-reap stale runs"
      when "admin_pause_polling"
        "Pause repository polling"
      when "admin_unpause_polling"
        "Resume repository polling"
      when "admin_pause_runs"
        "Pause runs"
      when "admin_unpause_runs"
        "Resume runs"
      when "admin_clear_github_cache"
        "Clear GitHub API cache"
      when "admin_pause_user_scheduling"
        "Pause scheduling for user ##{payload['user_id']}"
      when "admin_unpause_user_scheduling"
        "Resume scheduling for user ##{payload['user_id']}"
      when "admin_retry_step"
        "Retry step #{payload['step_slug']} on workflow ##{payload['workflow_id']}"
      when "admin_cleanup_workspace"
        "Delete workspace for workflow ##{payload['workflow_id']}"
      when "admin_refresh_installations"
        "Refresh GitHub App installations"
      when "manual_agentic_run"
        "Manual agentic run for #{job_slug(payload['job_id'])}"
      when "adopt_current_pr_head"
        "Adopt current PR head for #{job_slug(payload['job_id'])}"
      when "replace_pr_branch_with_workflow_output"
        "Replace PR branch for #{job_slug(payload['job_id'])}"
      when "retry_from_current_pr_branch"
        "Retry from current PR branch for #{job_slug(payload['job_id'])}"
      else
        payload["label"].presence || action.action_type.to_s.humanize
      end
    end

    def pending_action_detail(action)
      payload = action.payload || {}
      case action.action.presence || action.action_type
      when "close_job_successfully"
        payload["comment"].presence
      when "submit_chat_feedback"
        payload["feedback"].presence
      when "adopt_current_pr_head", "replace_pr_branch_with_workflow_output", "retry_from_current_pr_branch"
        evidence = payload["evidence"].to_h
        [
          "Remote SHA: #{evidence['remote_sha'].presence || 'unknown'}",
          "Workflow local SHA: #{evidence['workflow_local_sha'].presence || 'unknown'}",
          "Base SHA: #{evidence['base_sha'].presence || 'unknown'}",
          Array(evidence.dig("diff_summary", "files")).presence&.then { |files| "Changed files: #{files.first(10).join(', ')}" }
        ].compact.join("\n")
      when "schedule_recurring"
        [
          [ payload["label"], payload["schedule_explanation"] || payload["schedule_input"] || payload["cron_expression"] ].compact_blank.join(" — ").presence,
          payload["prompt"].presence
        ].compact.join("\n\n").presence
      when "submit_coding_changes"
        branch = payload["branch"].presence
        description = payload["description"].presence
        steps = <<~MARKDOWN.strip
          **Branch:** #{branch}

          1. Push branch to GitHub using server-side credentials
          2. Create a new direct Job
          3. Run the `coding_handoff` workflow (graders → summarize → PR open)
        MARKDOWN
        [ steps, description ].compact.join("\n\n---\n\n")
      end
    end
  end
end
