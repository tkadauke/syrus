module Coworkers
  class MentionableProvider
    class << self
      def mentionables(chat:)
        Coworkers::Coworker.joins(:coworker_chats).where(coworker_chats: { chat_session_id: chat.id }).includes(:handle_record)
      end

      def find_mentionable(kind:, id:)
        Coworkers::Coworker.find_by(id: id) if kind.to_s == "coworker"
      end
      # Until roster mutation ships, the owner's other coworkers are insertion
      # targets only. The resolver deliberately leaves their text unstructured.
      def autocomplete_mentionables(chat:, user:)
        return Coworkers::Coworker.none unless chat.user_id == user.id

        rostered_ids = Coworkers::Chat.where(chat_session_id: chat.id).select(:coworker_id)
        Coworkers::Coworker.where(owner_user: user).where.not(id: rostered_ids)
          .includes(:handle_record).order(Arel.sql("LOWER(name) ASC"), :id)
      end

      def share_candidates(user:)
        Coworkers::Coworker.where(owner_user: user).includes(:handle_record).order(Arel.sql("LOWER(name) ASC"), :id)
      end
    end
  end
end
