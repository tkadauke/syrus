module Api
  module V1
    module App
      class SharedChatsController < BaseController
        def show
          chat_session = ChatSession.where.not(share_token: nil).find_by!(share_token: params[:token])

          render json: shared_chat_payload(chat_session)
        end

        private

        def shared_chat_payload(chat_session)
          {
            chat: {
              id: chat_session.id,
              title: chat_session.title.presence || ChatSession.fallback_title_for(chat_session.repository)
            },
            messages: chat_session.messages.order(:created_at, :id).map { |message| shared_message_json(message) }
          }
        end

        def shared_message_json(message)
          text = message.content.is_a?(Hash) ? message.content["text"].to_s : message.content.to_s
          payload = {
            type: "message",
            id: message.id,
            role: message.role,
            tool_name: message.tool_name,
            content: message.content,
            text: text,
            bookmarkable: false
          }

          if message.content.is_a?(Hash) && message.content["attachments"].is_a?(Array)
            payload[:attachments] = message.content["attachments"]
          end

          payload
        end
      end
    end
  end
end
