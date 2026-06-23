module App
  class ChatMessagePayload
    include Rails.application.routes.url_helpers

    def self.messages(messages, repository:)
      new(repository: repository).messages(messages)
    end

    def initialize(repository:)
      @repository = repository
    end

    def messages(messages)
      messages.map { |message| message_json(message) }
    end

    private

    def message_json(message)
      text = message.content.is_a?(Hash) ? message.content["text"].to_s : message.content.to_s
      payload = {
        type: "message",
        id: message.id,
        role: message.role,
        tool_name: message.tool_name,
        content: message.content,
        text: text,
        bookmarkable: message.bookmarkable?
      }

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
        app_confirm_path: "/api/v1/app/chats/#{chat_session.id}/pending_actions/#{action.id}/confirm",
        app_reject_path: "/api/v1/app/chats/#{chat_session.id}/pending_actions/#{action.id}/reject"
      }

      case action.action.presence || action.action_type
      when "cancel_job", "retry_job", "rebase_job", "submit_chat_feedback"
        if (job = action.repository.jobs.find_by(id: payload["job_id"]))
          base.merge(resource_title: job.issue_title, resource_url: job_path(job))
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
      dependencies = proposal.dependencies.order(:slug).map { |dependency| dependency.slug }
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
        dependencies: dependencies,
        target_epic_label: proposal.target_epic&.display_number,
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

    def child_proposal_json(proposal, chat_session:)
      {
        id: proposal.id,
        title: proposal.title,
        slug: proposal.slug,
        body: proposal.body,
        state: proposal.state,
        state_label: proposal.state.humanize,
        proposed: proposal.proposed?,
        repository_slug: proposal.repository&.slug || @repository&.slug,
        dependencies: proposal.dependencies.order(:slug).map(&:slug),
        app_reject_path: "/api/v1/app/chats/#{chat_session.id}/proposals/#{proposal.id}/reject"
      }
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
      when "submit_chat_feedback"
        "Submit feedback on #{::App::Presentation.job_slug(payload['job_id'])}"
      when "reopen_epic_and_attach_job"
        "Reopen Epic ##{payload['epic_id']} and attach #{::App::Presentation.job_slug(payload['job_id'])}"
      else
        payload["label"].presence || action.action_type.to_s.humanize
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
