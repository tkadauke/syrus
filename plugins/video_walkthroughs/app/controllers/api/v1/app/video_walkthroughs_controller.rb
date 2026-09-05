module Api
  module V1
    module App
      # Multipart upload for walkthrough videos — deliberately NOT the chat
      # message base64 path (videos run 100-500MB; base64-in-JSON would 3x
      # the memory and blow request limits). The upload creates the
      # VideoWalkthroughs::Walkthrough, kicks the Gemini analysis job, and returns the
      # row; progress then streams over AppUserChannel
      # (video_walkthrough.analyzing → .analyzed | .failed).
      class VideoWalkthroughsController < BaseController
        def create
          chat = Current.user.accessible_chat_sessions.find(params[:chat_id])

          unless Current.user.gemini_configured?
            render_error("gemini_not_configured",
                         "Add a Gemini API key under Credentials to analyze walkthrough videos.",
                         status: :unprocessable_content)
            return
          end

          file = params[:file]
          unless file.respond_to?(:tempfile)
            render_error("missing_file", "Attach a video file.", status: :unprocessable_content)
            return
          end

          walkthrough = chat.video_walkthroughs.new(
            user: Current.user,
            title: params[:title].presence,
            # Persisted (not a transient job kwarg) so retries re-inject the
            # user's guidance instead of silently dropping it.
            note: params[:note].presence,
            duration_seconds: duration_param,
            byte_size: file.size,
            content_type: file.content_type.to_s
          )
          walkthrough.file.attach(io: file.tempfile, filename: file.original_filename.presence || "walkthrough.webm",
                                  content_type: file.content_type.to_s)

          if walkthrough.save
            VideoWalkthroughs::AnalysisJob.perform_later(walkthrough.id)
            render json: { video_walkthrough: walkthrough_json(walkthrough) }, status: :created
          else
            render_error("validation_failed", walkthrough.errors.full_messages.to_sentence,
                         status: :unprocessable_content)
          end
        end

        # Re-run a failed analysis (quota blips, transient network, or a
        # chat-delivery failure). The video is still in Active Storage and
        # the persisted note rides along; if the Gemini analysis already
        # succeeded, the job skips Gemini and just re-delivers the turn.
        def retry
          walkthrough = VideoWalkthroughs::Walkthrough.joins(:chat_session)
                                            .joins(chat_session: :chat_participants)
                                            .where(chat_participants: { user_id: Current.user.id })
                                            .find(params[:id])
          unless walkthrough.failed?
            render_error("not_retryable", "Only failed analyses can be retried.", status: :unprocessable_content)
            return
          end

          # Re-analysis needs the video; re-delivery (analysis already present)
          # doesn't. If the blob was pruned and we'd need to re-analyze, say so
          # cleanly instead of failing mid-job.
          if walkthrough.analysis.blank? && !walkthrough.file.attached?
            render_error("video_expired",
                         "This walkthrough's video has been cleaned up — record a new one to analyze it.",
                         status: :unprocessable_content)
            return
          end

          walkthrough.update!(state: "uploaded", error_message: nil)
          VideoWalkthroughs::AnalysisJob.perform_later(walkthrough.id)
          render json: { video_walkthrough: walkthrough_json(walkthrough) }
        end

        private

        # The client measures duration (HTMLVideoElement / the recorder
        # clock); the server has no ffmpeg and Gemini decodes the video
        # itself, so this is a UX gate, not a security boundary. Clamp to
        # sane integers; reject over-limit uploads via model validation.
        def duration_param
          value = params[:duration_seconds].to_i
          value.positive? ? value : nil
        end

        def walkthrough_json(walkthrough)
          {
            id: walkthrough.id,
            chat_session_id: walkthrough.chat_session_id,
            state: walkthrough.state,
            title: walkthrough.display_title,
            duration_seconds: walkthrough.duration_seconds,
            byte_size: walkthrough.byte_size,
            error_message: walkthrough.error_message,
            created_at: walkthrough.created_at.iso8601
          }
        end
      end
    end
  end
end
