module Api
  module V1
    module App
      class SpeechToTextController < BaseController
        before_action :require_speech_to_text_feature

        def create
          Current.user.chat_sessions.find(params[:chat_id])
          capability = ChatSpeechToText::Capability.for(user: Current.user)
          unless capability.backend_batch_available?
            render_error("speech_to_text_backend_unavailable", "Backend batch transcription is not configured.", status: :unprocessable_content)
            return
          end

          render_error("not_implemented", "Backend batch transcription is not implemented yet.", status: :not_implemented)
        end

        def stream
          Current.user.chat_sessions.find(params[:chat_id])
          capability = ChatSpeechToText::Capability.for(user: Current.user)
          unless capability.backend_streaming_available?
            render_error("speech_to_text_backend_unavailable", "Backend streaming transcription is not configured.", status: :unprocessable_content)
            return
          end

          render_error("not_implemented", "Backend streaming transcription is not implemented yet.", status: :not_implemented)
        end

        private

        def require_speech_to_text_feature
          return if Feature.chat_speech_to_text_enabled?

          render_error("speech_to_text_disabled", "Chat speech-to-text is not enabled.", status: :not_found)
        end
      end
    end
  end
end
