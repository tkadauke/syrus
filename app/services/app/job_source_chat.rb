module App
  class JobSourceChat
    include Rails.application.routes.url_helpers

    def self.for(job)
      new(job).payload
    end

    def initialize(job)
      @job = job
    end

    def payload
      proposal = source_proposal
      return unless proposal

      message_id = anchor_message_id(proposal)
      chat = proposal.chat_session
      path = chat_path(chat)
      path = "#{path}#message-#{message_id}" if message_id

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
      messages = proposal.messages
      if messages.loaded?
        messages.min_by(&:id)&.id
      else
        messages.order(:id).first&.id
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
