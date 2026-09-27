module App
  class JobDiscussionChatResolver
    RECENT_REPOSITORY_CHAT_WINDOW = 24.hours

    def initialize(job:, user:)
      @job = job
      @user = user
    end

    def resolve
      lineage_chat || recent_repository_chat || create_chat
    end

    private

    attr_reader :job, :user

    def lineage_chat
      proposal = confirmed_lineage_proposals
        .joins(chat_session: :chat_participants)
        .where(chat_participants: { user_id: user.id })
        .includes(:chat_session)
        .order(Arel.sql("COALESCE(chat_proposals.confirmed_at, chat_proposals.updated_at, chat_proposals.created_at) DESC"), id: :desc)
        .first

      proposal&.chat_session
    end

    def confirmed_lineage_proposals
      proposals = ChatProposal.confirmed.where(job_id: job.id)
      return proposals unless job.epic_id

      proposals.or(ChatProposal.confirmed.where(epic_id: job.epic_id))
    end

    def recent_repository_chat
      visible_chats
        .active
        .attached_to_repository(job.repository)
        .where("COALESCE(chat_sessions.last_message_at, chat_sessions.updated_at, chat_sessions.created_at) >= ?", RECENT_REPOSITORY_CHAT_WINDOW.ago)
        .order(Arel.sql("COALESCE(chat_sessions.last_message_at, chat_sessions.updated_at, chat_sessions.created_at) DESC"), id: :desc)
        .first
    end

    def create_chat
      ApplicationRecord.transaction do
        ChatSession.create!(user: user, repository: job.repository).tap do |chat|
          chat.chat_attachments.find_or_create_by!(attachable: job)
        end
      end
    end

    def visible_chats
      ChatSession
        .joins(:chat_participants)
        .where(chat_participants: { user_id: user.id })
        .distinct
    end
  end
end
