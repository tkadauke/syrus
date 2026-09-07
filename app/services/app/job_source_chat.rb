module App
  class JobSourceChat
    include Rails.application.routes.url_helpers

    # anchor: whether `path` should deep-link straight to the proposal
    # message. Job Detail renders this alongside a separate "View in chat"
    # bookmark deeplink (see App::JobDetailPayload#origin_chat_json), so it
    # asks for the plain chat path (anchor: false) to avoid two links
    # pointing at the exact same destination. Other consumers (e.g. the
    # dashboard job list) have no separate deeplink affordance, so they keep
    # the default anchored path.
    def self.for(job, anchor: true)
      new(job, anchor: anchor).payload
    end

    def initialize(job, anchor: true)
      @job = job
      @anchor = anchor
    end

    def payload
      proposal = source_proposal
      return unless proposal

      message_id = anchor_message_id(proposal)
      chat = proposal.chat_session
      path = chat_path(chat)
      path = "#{path}#message-#{message_id}" if @anchor && message_id

      {
        chat_id: chat.id,
        chat_title: chat.title.presence,
        proposal_id: proposal.id,
        proposal_kind: proposal.kind,
        message_id: message_id,
        path: path,
        label: label_for(proposal, chat)
      }
    end

    private

    attr_reader :job

    def source_proposal
      ordered_proposal(job.chat_proposals) ||
        (job.epic ? ordered_proposal(job.epic.chat_proposals) : nil)
    end

    def anchor_message_id(proposal)
      if proposal.association(:message_anchors).loaded?
        return proposal.message_anchors.first&.id
      end

      messages = proposal.messages
      if messages.loaded?
        messages.min_by(&:id)&.id
      else
        messages.reorder(:id).pick(:id)
      end
    end

    def ordered_proposal(association)
      if association.loaded?
        association.min_by { |proposal| [ proposal.created_at, proposal.id ] }
      else
        association.includes(:chat_session).order(:created_at, :id).first
      end
    end

    def label_for(proposal, chat)
      subject = proposal.job_id == job.id ? "Job proposal" : "Epic proposal"
      chat_title = chat.title.to_s.strip
      chat_title.present? ? "#{subject} in #{chat_title}" : subject
    end
  end
end
