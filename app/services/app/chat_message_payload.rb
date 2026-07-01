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
    end

    def messages(messages)
      messages.map { |message| message_json(message) }
    end

    private

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

      case action.action.presence || action.action_type
      when "cancel_job", "retry_job", "rebase_job", "reopen_job", "poll_job_feedback", "check_job_mergeability", "submit_chat_feedback"
        if (job = action.user.jobs.find_by(id: payload["job_id"]))
          base.merge(resource_title: job.issue_title, resource_url: job_path(job))
        else
          base
        end
      when "create_repo_document", "delete_repo_document"
        if (document = Document.find_by(id: payload["document_id"]))
          base.merge(resource_title: document.title)
        else
          base
        end
      when "reopen_epic_and_attach_job"
        if (epic = action.repository.epics.find_by(id: payload["epic_id"]))
          base.merge(resource_title: epic.title, resource_url: epic_path(epic))
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
      dependency_records = proposal.dependencies.order(:slug).reject { |dependency| epic_dependency_tokens.include?(dependency.slug) }
      epic_dependency_records = epic_dependency_json(proposal)
      visible_dependencies = dependency_records.map { |dependency| dependency_json(dependency) } + epic_dependency_records
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
        dependencies: visible_dependencies,
        has_dependencies: visible_dependencies.any?,
        target_epic_label: proposal.target_epic&.display_number,
        app_update_path: "/api/v1/app/chats/#{chat_session.id}/proposals/#{proposal.id}",
        app_confirm_path: "/api/v1/app/chats/#{chat_session.id}/proposals/#{proposal.id}/confirm",
        app_reject_path: "/api/v1/app/chats/#{chat_session.id}/proposals/#{proposal.id}/reject",
        materialized_label: proposal.materialized_label,
        materialized_path: materialized_path(materialized),
        materialized: materialized_json(proposal),
        # When the proposal became an Epic, expose its state + state-change path
        # so the chat can offer a "Start" (move to In Progress) action.
        materialized_epic_state: materialized_epic&.state,
        materialized_epic_state_path: materialized_epic ? "/api/v1/app/epics/#{materialized_epic.id}/state" : nil
      }

      if proposal.epic_bundle?
        child_proposals = proposal.child_proposals.includes(:repository, :dependencies).to_a
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
        anchor_message_id: proposal.messages.order(:id).last&.id,
        materialized_label: proposal.materialized_label,
        materialized_path: materialized_path(proposal.materialized_record)
      }
    end

    def epic_dependency_json(proposal)
      proposal.epic_dependency_tokens.filter_map do |token|
        if token.match?(/\Aepic:\d+\z/)
          epic = proposal.chat_session.user.epics.find_by(id: token.split(":", 2).last)
          next unless epic

          {
            slug: token,
            title: epic.display_number,
            display_label: epic.display_number,
            state: epic.state,
            confirmed: true,
            anchor_message_id: nil,
            materialized_path: epic_path(epic)
          }
        else
          dependency = proposal.chat_session.proposals.find_by(slug: token)
          if dependency&.confirmed? && dependency.epic
            {
              slug: token,
              title: dependency.epic.display_number,
              display_label: dependency.epic.display_number,
              state: dependency.epic.state,
              confirmed: true,
              anchor_message_id: dependency.messages.order(:id).last&.id,
              materialized_path: epic_path(dependency.epic)
            }
          else
            {
              slug: token,
              title: token,
              display_label: token,
              state: dependency&.state || "unresolved",
              confirmed: false,
              anchor_message_id: dependency&.messages&.order(:id)&.last&.id,
              materialized_path: nil
            }
          end
        end
      end
    end

    def child_proposal_json(proposal, chat_session:)
      dependency_records = proposal.dependencies.order(:slug).to_a
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

    def pending_action_label(action)
      payload = action.payload || {}
      case action.action
      when "add_repo_note"
        "Pin repository note"
      when "remove_repo_note"
        "Remove repository note ##{payload['id']}"
      when "cancel_job"
        "Cancel #{::App::Presentation.job_slug(payload['job_id'])}"
      when "retry_job"
        "Retry #{::App::Presentation.job_slug(payload['job_id'])}"
      when "rebase_job"
        "Rebase #{::App::Presentation.job_slug(payload['job_id'])}"
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
      else
        payload["label"].presence || action.action_type.to_s.humanize
      end
    end

    def pending_action_detail(action)
      payload = action.payload || {}
      case action.action.presence || action.action_type
      when "submit_chat_feedback"
        payload["feedback"].presence
      when "schedule_recurring"
        [
          [ payload["label"], payload["cron_expression"] ].compact_blank.join(" — ").presence,
          payload["prompt"].presence
        ].compact.join("\n\n").presence
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
