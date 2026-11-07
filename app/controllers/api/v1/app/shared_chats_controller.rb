module Api
  module V1
    module App
      class SharedChatsController < BaseController
        def show
          chat_session = ChatSession.where.not(share_token: nil).find_by!(share_token: params[:token])

          render json: shared_chat_payload(chat_session)
        end

        def attachment
          chat_session = ChatSession.where.not(share_token: nil).find_by!(share_token: params[:token])
          message = chat_session.messages.active.find(params[:message_id])
          attachment = ChatAttachmentRef.for(message).fetch(Integer(params[:index], 10))
          raise ActiveRecord::RecordNotFound, "Attachment file not found" unless attachment.bytes_present?

          expires_in 1.year, public: true, immutable: true
          send_secure_file attachment.bytes, filename: attachment.name, type: attachment.mime_type
        end

        private

        def shared_chat_payload(chat_session)
          messages = chat_session.messages.active.order(:created_at, :id).to_a
          ChatAttachmentRef.preload(messages)
          {
            chat: {
              id: chat_session.id,
              title: chat_session.title.presence || ChatSession.fallback_title_for(chat_session.repository)
            },
            messages: messages.map { |message| shared_message_json(message) }
          }
        end

        def shared_message_json(message)
          text = message.content.is_a?(Hash) ? message.content["text"].to_s : message.content.to_s
          payload = {
            type: "message",
            id: message.id,
            role: message.role,
            tool_name: message.tool_name,
            content: message.content.is_a?(Hash) ? message.content.except("text", "attachments") : message.content,
            text: text,
            bookmarkable: false
          }

          if message.content.is_a?(Hash) && message.content["attachments"].is_a?(Array)
            payload[:attachments] = ChatAttachmentRef.for(message).each_with_index.map do |attachment, index|
              attachment.payload.merge("url" => "/api/v1/app/shared_chats/#{message.chat_session.share_token}/messages/#{message.id}/attachments/#{index}")
            end
          end

          payload
        end
      end
    end
  end
end
