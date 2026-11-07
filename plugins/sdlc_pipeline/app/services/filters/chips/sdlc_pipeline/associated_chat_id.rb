module Filters
  module Chips
    module SdlcPipeline
      class AssociatedChatId < Base
        filter_name "associated_chat_id"
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
          chats = ChatSession.where(id: ids, user_id: user&.id, deleted_at: nil)
          matching_scope = scope.where(id: ChatAssociatedJobs.scope_for(chats).select(:id))

          case op
          when :is, :is_one_of then matching_scope
          when :is_not, :is_none_of then exclude_matches(matching_scope)
          else unsupported_op!
          end
        end
      end
    end
  end
end
