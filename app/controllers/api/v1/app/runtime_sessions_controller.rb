module Api
  module V1
    module App
      # Operator-facing surface for DOC-17 Runtime Sessions, backing the
      # Coding Mode right-sidebar Runtime panel. Read paths (index/show/logs)
      # mirror the runtime_* MCP tools' own resolution and JSON shape
      # (RuntimeSessionPresenter) so the agent and the human panel see the
      # same state; take_control/release_control are the operator's side of
      # DOC-17's Shared Human/Agent Control, acquiring/releasing leases with
      # owner: "user" instead of "agent".
      class RuntimeSessionsController < BaseController
        before_action :require_coding_mode_feature
        before_action :find_chat_session
        before_action :require_coding_chat
        before_action :find_runtime_session, except: [ :index ]

        # GET /api/v1/app/chats/:chat_id/runtime_sessions
        def index
          sessions = @chat_session.runtime_sessions.order(:created_at)
          render json: { runtime_sessions: sessions.map { |session| RuntimeSessionPresenter.session_payload(session) } }
        end

        # GET /api/v1/app/chats/:chat_id/runtime_sessions/:id
        def show
          render json: RuntimeSessionPresenter.session_payload(@runtime_session)
        end

        # GET /api/v1/app/chats/:chat_id/runtime_sessions/:id/logs
        def logs
          cursor = params[:cursor].presence || 0
          limit = params[:limit].presence
          result = provider_for(@runtime_session).logs(@runtime_session.id, cursor, { limit: limit }.compact)
          render json: result
        rescue RuntimeSessionProviders::ConfigurationError => e
          render_error("validation_failed", e.message, status: :unprocessable_content)
        end

        # POST /api/v1/app/chats/:chat_id/runtime_sessions/:id/capture
        def capture
          provider_for(@runtime_session).snapshot(@runtime_session.id, artifact_type: params[:artifact_type])
          render json: { runtime_session: RuntimeSessionPresenter.session_payload(@runtime_session.reload) }
        rescue RuntimeSessionProviders::ConfigurationError => e
          render_error("validation_failed", e.message, status: :unprocessable_content)
        rescue StandardError => e
          render_error("server_error", "Could not capture a runtime artifact: #{e.message}", status: :unprocessable_content)
        end

        # GET /api/v1/app/chats/:chat_id/runtime_sessions/:id/frame
        def frame
          document = Document.find_by(id: @runtime_session.metadata["latest_frame_document_id"])
          raise ActiveRecord::RecordNotFound, "No captured frame for this Runtime Session" unless document&.file&.attached?

          send_data(
            document.file.download,
            filename: document.filename || "frame.png",
            type: document.content_type || "image/png",
            disposition: "inline"
          )
        end

        # POST /api/v1/app/chats/:chat_id/runtime_sessions/:id/take_control
        # Operator-side runtime_acquire_control (owner: "user"). Always
        # aborts any active agent lease first -- DOC-17: "the operator can
        # always abort agent control immediately."
        def take_control
          mode = params[:mode].presence || "input"
          unless RuntimeControlLease::MODES.include?(mode) && mode != "observe_only"
            render_error("validation_failed", "mode must be one of: input, build, lifecycle", status: :unprocessable_content)
            return
          end

          RuntimeControlLease.abort_agent_control!(runtime_session: @runtime_session, reason: "operator took control")
          lease = RuntimeControlLease.acquire!(
            runtime_session: @runtime_session,
            owner: "user",
            owner_ref: "operator:#{Current.user.id}",
            mode: mode,
            reason: params[:reason].presence || "operator took control",
            duration_seconds: params[:duration_seconds]
          )

          render json: { runtime_session: RuntimeSessionPresenter.session_payload(@runtime_session.reload), lease: RuntimeSessionPresenter.lease_payload(lease) }
        rescue RuntimeControlLease::Conflict => e
          render_error("validation_failed", e.message, status: :unprocessable_content)
        rescue ActiveRecord::RecordInvalid => e
          render_error("validation_failed", e.record.errors.full_messages.to_sentence, status: :unprocessable_content)
        end

        # POST /api/v1/app/chats/:chat_id/runtime_sessions/:id/release_control
        # Operator-side runtime_release_control (owner: "user") -- releases
        # the operator's own active lease(s), returning control to the agent.
        def release_control
          released = @runtime_session.runtime_control_leases.active.held_by("user").map(&:release!)
          render json: { runtime_session: RuntimeSessionPresenter.session_payload(@runtime_session.reload), released: released.map { |lease| RuntimeSessionPresenter.lease_payload(lease) } }
        end

        private

        def require_coding_mode_feature
          render_error("feature_disabled", "Coding Mode is not enabled on this instance.", status: :not_found) unless Feature.coding_mode_enabled?
        end

        def find_chat_session
          @chat_session = Current.user.accessible_chat_sessions.active.find(params[:chat_id])
        end

        def require_coding_chat
          render_error("not_found", "Runtime Sessions are only available in Coding Mode chats.", status: :not_found) unless @chat_session.coding?
        end

        def find_runtime_session
          @runtime_session = @chat_session.runtime_sessions.find(params[:id])
        end

        def provider_for(runtime_session)
          RuntimeSessionProviders.for(runtime_session.provider_key).new
        end
      end
    end
  end
end
