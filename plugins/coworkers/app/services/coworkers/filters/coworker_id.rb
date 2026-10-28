module Coworkers
  module Filters
    class CoworkerId < ::Filters::Chips::Base
      SYRUS_VALUE = "syrus"

      filter_name "coworker_id"
      label "Coworker"
      bucket :enum
      operators :is, :is_not, :is_one_of, :is_none_of

      def self.schema_values(user)
        Coworkers::Coworker.where(owner_user: user).order(Arel.sql("LOWER(name) ASC"), :id).pluck(:id, :name).map do |id, name|
          { "value" => id.to_s, "label" => name }
        end.prepend({ "value" => SYRUS_VALUE, "label" => "Syrus" })
      end

      def apply
        handlers.fetch(op) { unsupported_op! }.call
      end

      private

      def handlers
        {
          is: -> { scope.where(chat_session_id: matching_chat_session_ids) },
          is_one_of: -> { scope.where(chat_session_id: matching_chat_session_ids) },
          is_not: -> { scope.where.not(chat_session_id: matching_chat_session_ids) },
          is_none_of: -> { scope.where.not(chat_session_id: matching_chat_session_ids) }
        }
      end

      def matching_chat_session_ids
        requested = Array(value).map(&:to_s)
        coworker_ids = requested.filter_map { |item| Integer(item, exception: false) }
        linked = Coworkers::Chat.where(coworker_id: coworker_ids).select(:chat_session_id)
        return linked unless requested.include?(SYRUS_VALUE)

        unlinked = ChatSession.where.not(id: Coworkers::Chat.select(:chat_session_id))
        unlinked.or(ChatSession.where(id: linked)).select(:id)
      end
    end
  end
end
