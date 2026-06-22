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

      payload
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
