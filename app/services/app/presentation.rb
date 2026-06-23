module App
  module Presentation
    GITHUB_APP_INSTALL_BASE_URL = "https://github.com/apps".freeze

    AGENT_PROVIDER_LABELS = {
      "claude" => "Claude Code",
      "codex" => "Codex"
    }.freeze

    module_function

    def agent_provider_label(provider)
      AGENT_PROVIDER_LABELS[provider] || provider.to_s.titleize
    end

    def job_slug(job_or_id)
      id = job_or_id.respond_to?(:id) ? job_or_id.id : job_or_id
      "JOB-#{id}"
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
      transitions << [ "Mark done", "done" ] if epic.in_progress? && epic.may_auto_complete?
      transitions << [ "Archive", "archived" ] if epic.may_archive?
      transitions
    end
  end
end
