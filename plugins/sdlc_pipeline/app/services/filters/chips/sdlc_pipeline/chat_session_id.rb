module Filters
  module Chips
    module SdlcPipeline
      class ChatSessionId < Base
        filter_name "chat_session_id"
        label "Associated chat"
        bucket :enum
        operators :is, :is_not, :is_one_of, :is_none_of

        def self.schema_values(user)
          ChatSession.where(user_id: user.id, deleted_at: nil).order(last_message_at: :desc).limit(100).map do |chat|
            { "value" => chat.id.to_s, "label" => chat.title.presence || "Chat ##{chat.id}" }
          end
        end

        def apply
          ids = Array(value).filter_map { |candidate| Integer(candidate, exception: false) }
          matches = ids.flat_map { |id| ChatSession.find_by(id: id, user_id: user&.id)&.then { |chat| ChatAssociatedJobs.scope(chat).select(:id) } }.compact
          matching_scope = matches.empty? ? scope.none : scope.where(id: matches.reduce { |left, right| left.or(right) })
          %i[is is_one_of].include?(op) ? matching_scope : exclude_matches(matching_scope)
        end
      end
    end
  end
end
