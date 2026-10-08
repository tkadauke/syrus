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
          render json: { runtime_sessions: sessions.map { |session| session_payload(session) } }
        end

        # GET /api/v1/app/chats/:chat_id/runtime_sessions/:id
        def show
          render json: session_payload(@runtime_session)
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
          render json: { runtime_session: session_payload(@runtime_session.reload) }
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

          render json: { runtime_session: session_payload(@runtime_session.reload), lease: RuntimeSessionPresenter.lease_payload(lease) }
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
          render json: { runtime_session: session_payload(@runtime_session.reload), released: released.map { |lease| RuntimeSessionPresenter.lease_payload(lease) } }
        end

        # POST /api/v1/app/chats/:chat_id/runtime_sessions/:id/renew_control
        # Heartbeat for the Runtime panel's Take Control button. Leases are
        # intentionally short (RuntimeControlLease::DEFAULT_DURATION/
        # MAX_DURATION are 30s/60s, per DOC-17's "short-lived and
        # auto-expire") so a sustained operator session extends its own
        # still-active lease in place instead of losing control mid-task.
        # Only ever touches the operator's own lease -- there is nothing to
        # renew if the agent holds it or it has already lapsed.
        def renew_control
          lease = @runtime_session.runtime_control_leases.active.held_by("user").first
          unless lease
            render_error("validation_failed", "You do not currently hold control of this runtime session.", status: :unprocessable_content)
            return
          end

          lease.renew!(duration_seconds: params[:duration_seconds])
          render json: { runtime_session: session_payload(@runtime_session.reload), lease: RuntimeSessionPresenter.lease_payload(lease) }
        rescue RuntimeControlLease::NotRenewable => e
          render_error("validation_failed", e.message, status: :unprocessable_content)
        end

        # POST /api/v1/app/chats/:chat_id/runtime_sessions/:id/input
        # Operator-side runtime_input. The Runtime panel may only deliver
        # pointer/keyboard/text events while the current operator holds an
        # active user input lease; the provider still performs its own lease
        # check with caller ownership metadata before touching the target.
        def input
          event = params[:event]
          unless event.is_a?(ActionController::Parameters) || event.is_a?(Hash)
            render_error("validation_failed", "event must be an object", status: :unprocessable_content)
            return
          end

          lease = current_user_input_lease
          unless lease
            RuntimeControlLease.audit_input_rejected!(runtime_session: @runtime_session, event: input_event_hash(event))
            render_error("validation_failed", "You must take input control before sending runtime input.", status: :unprocessable_content)
            return
          end

          payload = input_event_hash(event).merge("_runtime_control_owner" => "user")
          result = provider_for(@runtime_session).input(@runtime_session.id, payload)
          if provider_input_error?(result)
            render_error("validation_failed", provider_input_error_message(result), status: :unprocessable_content)
            return
          end

          render json: { result: result, runtime_session: session_payload(@runtime_session.reload) }
        rescue RuntimeSessionProviders::ConfigurationError => e
          render_error("validation_failed", e.message, status: :unprocessable_content)
        rescue StandardError => e
          render_error("server_error", "Could not deliver runtime input: #{e.message}", status: :unprocessable_content)
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

        def session_payload(runtime_session)
          RuntimeSessionPresenter.session_payload(runtime_session).merge(
            active_user_input_lease: RuntimeSessionPresenter.lease_payload(current_user_input_lease(runtime_session))
          )
        end

        def current_user_input_lease(runtime_session = @runtime_session)
          runtime_session.runtime_control_leases.active
            .held_by("user")
            .for_mode("input")
            .find_by(owner_ref: "operator:#{Current.user.id}")
        end

        def input_event_hash(event)
          event.respond_to?(:to_unsafe_h) ? event.to_unsafe_h : event.to_h
        end

        def provider_input_error?(result)
          error = result.is_a?(Hash) ? result[:error] || result["error"] : nil
          error.present? && error != false
        end

        def provider_input_error_message(result)
          return "Runtime provider rejected the input event." unless result.is_a?(Hash)

          result[:message].presence ||
            result["message"].presence ||
            result[:error].presence ||
            result["error"].presence ||
            "Runtime provider rejected the input event."
        end
      end
    end
  end
end
