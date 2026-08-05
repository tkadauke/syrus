module Api
  module V1
    module App
      class SpeechToTextController < BaseController
        ALLOWED_AUDIO_CONTENT_TYPES = ChatSpeechToText::AudioConstraints::ALLOWED_CONTENT_TYPES
        MAX_AUDIO_BYTES = ChatSpeechToText::AudioConstraints::MAX_BYTES
        MAX_AUDIO_DURATION_SECONDS = ChatSpeechToText::AudioConstraints::MAX_DURATION_SECONDS

        before_action :require_speech_to_text_feature

        def create
          Current.user.chat_sessions.find(params[:chat_id])
          capability = ChatSpeechToText::Capability.for(user: Current.user)
          provider = capability.backend_provider
          unless capability.backend_batch_available? && provider
            render_error("speech_to_text_backend_unavailable", "Backend batch transcription is not configured.", status: :unprocessable_content)
            return
          end

          file = params[:file]
          unless file.respond_to?(:tempfile)
            render_error("missing_file", "Attach an audio file.", status: :unprocessable_content)
            return
          end
          return unless validate_audio_file(file)

          result = provider.transcribe_batch(
            ChatSpeechToText::Providers::TranscriptionRequest.new(
              audio: file.tempfile,
              content_type: normalized_content_type(file.content_type),
              language: params[:language].presence,
              prompt: params[:prompt].presence
            )
          )

          render json: {
            transcript: {
              text: result.text.to_s,
              source: "backend_batch",
              confidence: result.confidence
            }
          }
        rescue ChatSpeechToText::Providers::TranscriptionError => e
          render_error("speech_to_text_transcription_failed", e.message.presence || "Backend transcription failed.", status: :bad_gateway)
        end

        def stream
          chat = Current.user.chat_sessions.find(params[:chat_id])
          capability = ChatSpeechToText::Capability.for(user: Current.user)
          unless capability.backend_streaming_available?
            render_error("speech_to_text_backend_unavailable", "Backend streaming transcription is not configured.", status: :unprocessable_content)
            return
          end

          render json: {
            stream: {
              transport: "action_cable",
              channel: "ChatDictationChannel",
              chat_session_id: chat.id,
              events: %w[started ack transcript_delta done cancelled error],
              fallback: {
                mode: "backend_batch",
                buffered_audio_required: true,
                endpoint: "/api/v1/app/chats/#{chat.id}/speech_to_text"
              }
            }
          }
        end

        private

        def require_speech_to_text_feature
          return if Feature.chat_speech_to_text_enabled?

          render_error("speech_to_text_disabled", "Chat speech-to-text is not enabled.", status: :not_found)
        end

        def validate_audio_file(file)
          unless allowed_audio_content_type?(file.content_type)
            render_error("unsupported_content_type", "Upload a supported audio file.", status: :unprocessable_content)
            return false
          end

          if file.size.to_i > MAX_AUDIO_BYTES
            render_error("audio_too_large", "Audio uploads must be 10 MB or smaller.", status: :content_too_large)
            return false
          end

          duration = duration_param
          if duration && duration > MAX_AUDIO_DURATION_SECONDS
            render_error("audio_too_long", "Audio uploads must be 120 seconds or shorter.", status: :unprocessable_content)
            return false
          end

          true
        end

        def allowed_audio_content_type?(content_type)
          ALLOWED_AUDIO_CONTENT_TYPES.include?(normalized_content_type(content_type))
        end

        def normalized_content_type(content_type)
          content_type.to_s.split(";", 2).first.to_s.downcase
        end

        def duration_param
          value = params[:duration_seconds].to_i
          value.positive? ? value : nil
        end
      end
    end
  end
end
