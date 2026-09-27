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
      source = App::JobSourceChat.for(job, anchor: false)
      chat_id = source&.fetch(:chat_id, nil)
      return unless chat_id

      visible_chats.find_by(id: chat_id)
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
