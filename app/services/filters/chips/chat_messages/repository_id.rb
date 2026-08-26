module Filters
  module Chips
    module ChatMessages
      # ChatMessage has no repository_id column of its own — a chat is
      # linked to a repository through its ChatSession's polymorphic
      # repository ChatAttachment(s). Filter via that join instead of
      # the generic column-based RepositoryId chip.
      class RepositoryId < Base
        filter_name "repository_id"
        label "Repository"
        bucket :fk
        operators :is, :is_not, :is_one_of, :is_none_of

        def apply
          case op
          when :is, :is_one_of        then scope.where(chat_session_id: attached_chat_session_ids)
          when :is_not, :is_none_of   then scope.where.not(chat_session_id: attached_chat_session_ids)
          else unsupported_op!
          end
        end

        private

        def attached_chat_session_ids
          ChatAttachment.where(attachable_type: "Repository", attachable_id: Array(value)).select(:chat_session_id)
        end
      end
    end
  end
end
