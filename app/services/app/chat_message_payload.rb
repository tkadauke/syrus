module App
  class ChatMessagePayload
    include Rails.application.routes.url_helpers

    def self.messages(messages, repository:)
      new(repository: repository).messages(messages)
    end

    def self.proposal(proposal, chat_session:, repository:)
      new(repository: repository).send(:proposal_json, proposal, chat_session: chat_session)
    end

    def initialize(repository:)
      @repository = repository
      @proposal_by_chat_and_slug = {}
      @jobs_by_user_and_id = {}
      @epics_by_user_and_id = {}
      @documents_by_id = {}
      @repositories_by_user_and_id = {}
    end

    def messages(messages)
      records = messages.to_a
      preload_message_associations(records)
      records.map { |message| message_json(message) }
    end

    private

    def preload_message_associations(messages)
      return if messages.blank?

      ActiveRecord::Associations::Preloader.new(
        records: messages,
        associations: [
          :chat_session,
          :pending_action,
          {
            proposal: [
              :chat_session,
              :repository,
              :job,
              :epic,
              :target_epic,
              :messages,
              { dependencies: [ :chat_session, :repository, :job, :epic, :messages ] },
              { child_proposals: [
                :chat_session,
                :repository,
                :job,
                :epic,
                :messages,
                { dependencies: [ :chat_session, :repository, :job, :epic, :messages ] }
              ] }
            ]
          }
        ]
      ).call
    end

    def message_json(message)
      text = text_from_content(message)
      payload = {
        type: "message",
        id: message.id,
        role: message.role,
        tool_name: message.tool_name,
        content: message.content,
        text: text,
        bookmarkable: message.bookmarkable?,
        created_at: message.created_at.iso8601
      }

      payload[:attachments] = message.content["attachments"] if message.content.is_a?(Hash) && message.content["attachments"].is_a?(Array)
      payload[:video_walkthrough_id] = message.content["video_walkthrough_id"] if message.content.is_a?(Hash) && message.content["video_walkthrough_id"].present?
      payload[:proposal] = proposal_json(message.proposal, chat_session: message.chat_session) if message.proposal_id.present?
      payload[:pending_action] = pending_action_json(message.pending_action, chat_session: message.chat_session) if message.pending_action_id.present?

      payload
    end

    def pending_action_json(action, chat_session:)
      return nil unless action

      payload = action.payload || {}
      base = {
        id: action.id,
        action: action.action.presence || action.action_type,
        state: action.state,
        label: pending_action_label(action),
        detail: pending_action_detail(action),
        app_confirm_path: "/api/v1/app/chats/#{chat_session.id}/pending_actions/#{action.id}/confirm",
        app_reject_path: "/api/v1/app/chats/#{chat_session.id}/pending_actions/#{action.id}/reject"
      }
      base[:reason] = action.reason if action.reason.present?
      base[:before_snapshot] = action.before_snapshot if action.before_snapshot.present?
      base[:after_snapshot] = action.after_snapshot if action.after_snapshot.present?

      case action.action.presence || action.action_type
      when "cancel_job", "close_job_successfully", "retry_job", "force_fail_job", "rebase_job", "force_rebase", "reopen_job", "poll_job_feedback", "check_job_mergeability", "submit_chat_feedback", "force_landing_recheck", "override_landing_blocker_once"
        if (job = cached_action_job(action, payload["job_id"]))
          base.merge(resource_title: job.issue_title, resource_url: job_path(job))
        else
          base
        end
      when "restack_epic"
        if (epic = cached_action_epic(action, payload["epic_id"]))
          base.merge(resource_title: epic.title, resource_url: epic_path(epic))
        else
          base
        end
      when "create_repo_document", "delete_repo_document"
        if (document = cached_document(payload["document_id"]))
          base.merge(resource_title: document.title)
        else
          base
        end
      when "reopen_epic_and_attach_job"
        if (epic = cached_repository_epic(action.repository, payload["epic_id"]))
          base.merge(resource_title: epic.title, resource_url: epic_path(epic))
        else
          base
        end
      when "submit_coding_changes"
        if (repo = cached_user_repository(action.user, payload["repository_id"]))
          base.merge(resource_title: repo.slug, resource_url: repository_path(repo))
        else
          base
        end
      else
        base
      end
    end

    def proposal_json(proposal, chat_session:)
      return nil unless proposal

      materialized = proposal.materialized_record
      materialized_epic = materialized.is_a?(Epic) ? materialized : nil
      scoped_repository = proposal.effective_repository || @repository
      epic_dependency_tokens = proposal.epic_dependency_tokens
      dependency_records = ordered_dependencies(proposal).reject { |dependency| epic_dependency_tokens.include?(dependency.slug) }
      epic_dependency_records = epic_dependency_json(proposal)
      job_id_dependency_records = job_id_dependency_json(proposal)
      epic_id_dependency_records = epic_id_dependency_json(proposal)
      visible_dependencies = dependency_records.map { |dependency| dependency_json(dependency) } + epic_dependency_records + job_id_dependency_records + epic_id_dependency_records
      dependency_slugs = dependency_records.map(&:slug) + epic_dependency_tokens
      base = {
        id: proposal.id,
        kind: proposal.kind,
        kind_label: proposal.kind.to_s.humanize,
        state: proposal.state,
        state_label: proposal.state.humanize,
        title: proposal.title,
        slug: proposal.slug,
        body: proposal.body,
        proposed: proposal.proposed?,
        resolved: proposal.resolved?,
        epic_bundle: proposal.epic_bundle?,
        scoped_repository_slug: scoped_repository&.slug,
        dependency_slugs: dependency_slugs,
        depends_on_job_ids: proposal.depends_on_job_ids || [],
        depends_on_epic_ids: proposal.depends_on_epic_ids || [],
        nonlinear_dependency_override: proposal.nonlinear_dependency_override?,
        dependencies: visible_dependencies,
        has_dependencies: visible_dependencies.any?,
        target_epic_label: proposal.target_epic&.slug,
        app_update_path: "/api/v1/app/chats/#{chat_session.id}/proposals/#{proposal.id}",
        app_confirm_path: "/api/v1/app/chats/#{chat_session.id}/proposals/#{proposal.id}/confirm",
        app_reject_path: "/api/v1/app/chats/#{chat_session.id}/proposals/#{proposal.id}/reject",
        materialized_label: proposal.materialized_label,
        materialized_path: materialized_path(materialized),
        materialized: materialized_json(proposal),
        # When the proposal became an Epic, expose its state + state-change path
        # so the chat can offer a "Start" (move to In Progress) action.
        materialized_epic_state: materialized_epic&.state,
        materialized_epic_state_path: materialized_epic ? "/api/v1/app/epics/#{materialized_epic.id}/state" : nil,
        media_ids: proposal.media_ids || []
      }

      if proposal.epic_bundle?
        child_proposals = ordered_child_proposals(proposal)
        active_children = child_proposals.reject(&:rejected?)
        base.merge(
          active_children_count: active_children.size,
          children: child_proposals.map { |child| child_proposal_json(child, chat_session: chat_session) }
        )
      else
        base
      end
    end

    def dependency_json(proposal)
      {
        slug: proposal.slug,
        title: proposal.title,
        state: proposal.state,
        confirmed: proposal.confirmed?,
        anchor_message_id: anchor_message_id(proposal),
        materialized_label: proposal.materialized_label,
        materialized_path: materialized_path(proposal.materialized_record)
      }
    end

    def epic_dependency_json(proposal)
      proposal.epic_dependency_tokens.filter_map do |token|
        if token.match?(/\Aepic:\d+\z/)
          epic = cached_user_epics(proposal.chat_session.user, [ token.split(":", 2).last.to_i ])[token.split(":", 2).last.to_i]
          next unless epic

          {
            slug: token,
            title: epic.slug,
            display_label: epic.slug,
            state: epic.state,
            confirmed: true,
            anchor_message_id: nil,
            materialized_path: epic_path(epic)
          }
        else
          dependency = proposal_for_slug(proposal.chat_session, token)
          if dependency&.confirmed? && dependency.epic
            {
              slug: token,
              title: dependency.epic.slug,
              display_label: dependency.epic.slug,
              state: dependency.epic.state,
              confirmed: true,
              anchor_message_id: anchor_message_id(dependency),
              materialized_path: epic_path(dependency.epic)
            }
          else
            {
              slug: token,
              title: token,
              display_label: token,
              state: dependency&.state || "unresolved",
              confirmed: false,
              anchor_message_id: dependency ? anchor_message_id(dependency) : nil,
              materialized_path: nil
            }
          end
        end
      end
    end

    def job_id_dependency_json(proposal)
      job_ids = proposal.depends_on_job_ids.presence
      return [] if job_ids.blank?

      job_records = cached_user_jobs(proposal.chat_session.user, job_ids)
      job_ids.filter_map { |id| job_records[id] }.map do |job|
        {
          slug: job.slug,
          title: job.title,
          state: job.state,
          confirmed: true,
          anchor_message_id: nil,
          materialized_label: job.slug,
          materialized_path: job_path(job)
        }
      end
    end

    def epic_id_dependency_json(proposal)
      epic_ids = proposal.depends_on_epic_ids.presence
      return [] if epic_ids.blank?

      epic_records = cached_user_epics(proposal.chat_session.user, epic_ids)
      epic_ids.filter_map { |id| epic_records[id] }.map do |epic|
        {
          slug: "epic:#{epic.id}",
          title: epic.slug,
          display_label: epic.slug,
          state: epic.state,
          confirmed: true,
          anchor_message_id: nil,
          materialized_path: epic_path(epic)
        }
      end
    end

    def child_proposal_json(proposal, chat_session:)
      dependency_records = ordered_dependencies(proposal)
      {
        id: proposal.id,
        title: proposal.title,
        slug: proposal.slug,
        body: proposal.body,
        state: proposal.state,
        state_label: proposal.state.humanize,
        proposed: proposal.proposed?,
        repository_slug: proposal.repository&.slug || @repository&.slug,
        dependencies: dependency_records.map(&:slug),
        depends_on_job_ids: proposal.depends_on_job_ids || [],
        depends_on_epic_ids: proposal.depends_on_epic_ids || [],
        dependency_details: dependency_records.map { |dependency| child_dependency_json(proposal, dependency) },
        app_update_path: "/api/v1/app/chats/#{chat_session.id}/proposals/#{proposal.id}",
        app_reject_path: "/api/v1/app/chats/#{chat_session.id}/proposals/#{proposal.id}/reject"
      }
    end

    def child_dependency_json(proposal, dependency)
      {
        slug: dependency.slug,
        title: dependency.title,
        scope: dependency.parent_proposal_id == proposal.parent_proposal_id ? "sibling" : "cross_card",
        confirmed: dependency.confirmed?,
        materialized_label: dependency.materialized_label,
        materialized_path: materialized_path(dependency.materialized_record)
      }
    end

    def text_from_content(message)
      content = message.content
      if content.is_a?(Array)
        # Canonical format: content-blocks array — extract text blocks only
        content.filter_map { |b| b["text"] if b.is_a?(Hash) && b["type"] == "text" }.join
      elsif content.is_a?(Hash)
        content["text"].to_s
      else
        content.to_s
      end
    end

    def materialized_path(record)
      case record
      when Job then job_path(record)
      when Epic then epic_path(record)
      end
    end

    def ordered_dependencies(proposal)
      records = proposal.dependencies.loaded? ? proposal.dependencies.to_a : proposal.dependencies.includes(:job, :epic, :messages).to_a
      records.sort_by(&:slug)
    end

    def ordered_child_proposals(proposal)
      records = proposal.child_proposals.loaded? ? proposal.child_proposals.to_a : proposal.child_proposals.includes(:repository, :job, :epic, :messages, dependencies: [ :job, :epic, :messages ]).to_a
      records.sort_by { |child| [ child.child_position || 0, child.created_at || Time.at(0), child.id || 0 ] }
    end

    def anchor_message_id(proposal)
      if proposal.messages.loaded?
        proposal.messages.max_by(&:id)&.id
      else
        proposal.messages.order(:id).last&.id
      end
    end

    def proposal_for_slug(chat_session, slug)
      key = [ chat_session.id, slug.to_s ]
      @proposal_by_chat_and_slug.fetch(key) do
        scope = chat_session.proposals
        proposal = if scope.loaded?
          scope.detect { |candidate| candidate.slug == slug }
        else
          scope.includes(:epic, :messages).find_by(slug: slug)
        end
        @proposal_by_chat_and_slug[key] = proposal
      end
    end

    def cached_user_jobs(user, ids)
      cache = @jobs_by_user_and_id[user.id] ||= {}
      missing_ids = ids.map(&:to_i).uniq - cache.keys
      cache.merge!(user.jobs.where(id: missing_ids).index_by(&:id)) if missing_ids.any?
      cache
    end

    def cached_user_epics(user, ids = nil)
      cache = @epics_by_user_and_id[user.id] ||= {}
      missing_ids = Array(ids).map(&:to_i).uniq - cache.keys
      cache.merge!(user.epics.where(id: missing_ids).index_by(&:id)) if missing_ids.any?
      cache
    end

    def cached_action_job(action, id)
      id = id.to_i
      return if id <= 0

      if action.user.admin?
        @admin_jobs_by_id ||= {}
        @admin_jobs_by_id[id] ||= Job.find_by(id: id)
      else
        cached_user_jobs(action.user, [ id ])[id]
      end
    end

    def cached_action_epic(action, id)
      id = id.to_i
      return if id <= 0

      if action.user.admin?
        @admin_epics_by_id ||= {}
        @admin_epics_by_id[id] ||= Epic.find_by(id: id)
      else
        cached_user_epics(action.user, [ id ])[id]
      end
    end

    def cached_document(id)
      id = id.to_i
      return if id <= 0

      @documents_by_id[id] ||= Document.find_by(id: id)
    end

    def cached_repository_epic(repository, id)
      id = id.to_i
      return if id <= 0 || !repository

      cached_user_epics(repository.user, [ id ])[id]&.then { |epic| epic.repository_id == repository.id ? epic : nil }
    end

    def cached_user_repository(user, id)
      id = id.to_i
      return if id <= 0

      cache = @repositories_by_user_and_id[user.id] ||= {}
      cache[id] ||= user.repositories.active.find_by(id: id)
    end

    def pending_action_label(action)
      payload = action.payload || {}
      case action.action
      when "cancel_job"
        "Cancel #{::App::Presentation.job_slug(payload['job_id'])}"
      when "close_job_successfully"
        "Close #{::App::Presentation.job_slug(payload['job_id'])} as #{payload['closure_reason']}"
      when "retry_job"
        "Retry #{::App::Presentation.job_slug(payload['job_id'])}"
      when "force_fail_job"
        "Force fail #{::App::Presentation.job_slug(payload['job_id'])}"
      when "rebase_job"
        "Rebase #{::App::Presentation.job_slug(payload['job_id'])}"
      when "force_rebase"
        "Force rebase #{::App::Presentation.job_slug(payload['job_id'])}"
      when "restack_epic"
        "Restack Epic ##{payload['epic_id']}"
      when "reopen_job"
        "Reopen #{::App::Presentation.job_slug(payload['job_id'])}"
      when "fire_scheduled_task_now"
        "Fire scheduled task ##{payload['scheduled_task_id']}"
      when "create_repo_document"
        "Create document #{payload['title'].to_s.inspect}"
      when "delete_repo_document"
        "Delete document #{payload['title'].to_s.presence || "##{payload['document_id']}"}"
      when "poll_job_feedback"
        "Poll PR feedback for #{::App::Presentation.job_slug(payload['job_id'])}"
      when "check_job_mergeability"
        "Check mergeability for #{::App::Presentation.job_slug(payload['job_id'])}"
      when "force_landing_recheck"
        "Force landing recheck for #{::App::Presentation.job_slug(payload['job_id'])}"
      when "override_landing_blocker_once"
        "Override #{payload['blocker_key']} once for #{::App::Presentation.job_slug(payload['job_id'])}"
      when "wake_landing_queue"
        "Wake landing queue"
      when "delegate_issue"
        "Delegate issue ##{payload['issue_number']}"
      when "pause_landing_queue"
        "Pause landing queue"
      when "resume_landing_queue"
        "Resume landing queue"
      when "submit_chat_feedback"
        "Submit feedback on #{::App::Presentation.job_slug(payload['job_id'])}"
      when "reopen_epic_and_attach_job"
        "Reopen Epic ##{payload['epic_id']} and attach #{::App::Presentation.job_slug(payload['job_id'])}"
      when "submit_coding_changes"
        payload["title"].presence || action.action_type.to_s.humanize
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
      when "schedule_recurring"
        [
          [ payload["label"], payload["cron_expression"] ].compact_blank.join(" — ").presence,
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

    def materialized_json(proposal)
      return { kind: "rejected", reason: proposal.state } if proposal.rejected? || proposal.withdrawn?

      case proposal.materialized_record
      when Job
        {
          kind: "job",
          job_id: proposal.job.id,
          job_title: proposal.job.issue_title,
          job_state: proposal.job.state
        }
      when Epic
        {
          kind: "epic",
          epic_id: proposal.epic.id,
          epic_title: proposal.epic.title,
          child_jobs: proposal.child_proposals.confirmed.includes(:job).map do |child|
            { job_id: child.job_id, title: child.job&.issue_title }
          end
        }
      end
    end
  end
end
