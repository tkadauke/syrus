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

    # The canonical, compact Syrus Job identifier shown everywhere in the
    # app (chat proposal confirmations, dependency badges, pending-action
    # labels, PR backlinks, admin/insight payloads). Deliberately ignores
    # the descriptive `jobs.slug` column here — that column is a
    # human-readable, title-derived value meant for typed references
    # (`syrus checkout <slug>`, JobEpicRefFinder) and for list-style UI
    # that opts in explicitly (see ChatJobStatusQuery), not for the
    # identifier operators and agents use to refer to a Job in prose.
    def job_slug(job_or_id)
      id = job_or_id.respond_to?(:id) ? job_or_id.id : job_or_id
      "JOB-#{id}"
    end

    def epic_slug(epic_or_number)
      number = epic_or_number.respond_to?(:number) ? epic_or_number.number : epic_or_number
      "EPIC-#{number}"
    end

    def chat_slug(chat_or_id)
      id = chat_or_id.respond_to?(:id) ? chat_or_id.id : chat_or_id
      "CHAT-#{id}"
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
      workflow = WorkUnits::Ownership
        .active_workflows_by_job_id([ job.id ], states: [ "running" ])
        .fetch(job.id, nil)
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
    #
    # The actual rendering lives on the PendingActions::Base hierarchy
    # (app/services/pending_actions/) -- the same class that already owns
    # execution, payload validation, and audit detail for that action key --
    # via its presentation_label/presentation_detail methods. That keeps a
    # plugin-provided action (e.g. PendingActions::ScheduleRecurring from the
    # scheduled_tasks plugin) able to define its own chat-card presentation
    # without editing a core presentation registry.
    def pending_action_label(action)
      pending_action_presenter(action).presentation_label
    rescue PendingActions::UnknownAction
      pending_action_fallback_label(action)
    end

    # Groups are homogeneous by construction (see PendingActionGroup) so a
    # single shared action/action_type covers every member in practice; the
    # mixed-action fallback only guards against a future caller that doesn't
    # honor that convention.
    def pending_action_group_label(members)
      action_keys = members.map { |member| member.action.presence || member.action_type }.uniq
      return "Batch action (#{members.size})" if action_keys.size != 1 || action_keys.first.blank?

      "#{action_keys.first.to_s.humanize} (#{members.size})"
    end

    def pending_action_detail(action)
      pending_action_presenter(action).presentation_detail
    rescue PendingActions::UnknownAction
      nil
    end

    def pending_action_presenter(action)
      PendingActions.for(action.action.presence || action.action_type).new(action)
    end

    # Mirrors PendingActions::Base#presentation_label's conservative default,
    # for an action key with no registered PendingActions class at all (e.g.
    # a future action_type not yet implemented) -- PendingActions.for raises
    # before a presenter instance even exists to fall back on its own.
    def pending_action_fallback_label(action)
      payload = action.payload || {}
      payload["label"].presence || (action.action.presence || action.action_type).to_s.humanize
    end
  end
end
