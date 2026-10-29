module Coworkers
  class MentionableProvider
    class << self
      def mentionables(chat:)
        own_chat_ids = Coworkers::Chat.where(chat_session_id: chat.id).select(:coworker_id)
        roster_ids = Coworkers::ChatAgent.where(chat_session_id: chat.id).select(:coworker_id)
        Coworkers::Coworker.where(id: own_chat_ids).or(Coworkers::Coworker.where(id: roster_ids)).includes(:handle_record).order(:id)
      end

      def find_mentionable(kind:, id:)
        Coworkers::Coworker.find_by(id: id) if kind.to_s == "coworker"
      end
      def autocomplete_mentionables(chat:, user:)
        return Coworkers::Coworker.none unless chat.user_id == user.id

        rostered_ids = mentionables(chat: chat).select(:id)
        Coworkers::Coworker.where(owner_user: user).where.not(id: rostered_ids)
          .includes(:handle_record).order(Arel.sql("LOWER(name) ASC"), :id)
      end

      def share_candidates(user:)
        Coworkers::Coworker.where(owner_user: user).includes(:handle_record).order(Arel.sql("LOWER(name) ASC"), :id)
      end
    end
  end
end
