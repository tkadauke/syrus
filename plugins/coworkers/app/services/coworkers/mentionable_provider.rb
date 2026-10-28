module Coworkers
  class MentionableProvider
    class << self
      def mentionables(chat:)
        Coworkers::Coworker.joins(:coworker_chats).where(coworker_chats: { chat_session_id: chat.id }).includes(:handle_record)
      end

      def find_mentionable(kind:, id:)
        Coworkers::Coworker.find_by(id: id) if kind.to_s == "coworker"
      end
      def share_candidates(user:)
        Coworkers::Coworker.where(owner_user: user).includes(:handle_record).order(Arel.sql("LOWER(name) ASC"), :id)
      end
    end
  end
end
