module Api
  module V1
    module App
      class TerminalSessionsController < BaseController
        def index
          render json: sessions_payload
        end

        def create
          session = ::Terminal::Session.create!(
            user: Current.user,
            workflow: session_attributes[:workflow],
            chat_session: session_attributes[:chat_session],
            name: session_attributes[:name],
            working_directory: session_attributes[:working_directory],
            worker_hostname: session_attributes[:worker_hostname],
            worker_storage_key: session_attributes[:worker_storage_key],
            queue_name: session_attributes[:queue_name],
            workspace_kind: session_attributes[:workspace_kind],
            auth_token: SecureRandom.hex(32),
            started_at: Time.current
          )
          TerminalSessionJob.set(queue: session.target_queue_name).perform_later(session.id)

          render json: { session: session_json(session) }, status: :created
        end

        def show
          render json: { session: session_json(find_session) }
        end

        def kill
          destroy
        end

        # Polled by the chrome to badge the nav entry (badge_api_path).
        def open_count
          render json: { count: ::Terminal::Session.where(user: Current.user).running.count }
        end

        def destroy
          session = ::Terminal::KillSession.call(find_session)

          render json: { session: session_json(session) }
        end

        private

        def find_session
          ::Terminal::Session.where(user: Current.user).find(params[:id])
        end

        def sessions_payload
          {
            sessions: ::Terminal::Session.where(user: Current.user).running.order(started_at: :desc).map { |session| session_json(session) },
            workspaces: workspace_json
          }
        end

        def session_json(session)
          ::Terminal::SessionSerializer.render(session)
        end

        def workspace_json
          ::Terminal::WorkspaceCandidates.for(user: Current.user)
        end

        def selected_candidate
          return @selected_candidate if defined?(@selected_candidate)

          key = terminal_session_params[:candidate_key]
          return @selected_candidate = nil if key.blank?

          @selected_candidate = ::Terminal::WorkspaceCandidates.find(user: Current.user, key: key)
          raise ActiveRecord::RecordNotFound, "terminal workspace candidate not found" unless @selected_candidate

          @selected_candidate
        end

        def selected_workflow
          return @selected_workflow if defined?(@selected_workflow)
          return @selected_workflow = selected_candidate_workflow if selected_candidate

          workflow_id = terminal_session_params[:workflow_id]
          return @selected_workflow = nil if workflow_id.blank?

          @selected_workflow = Current.user.workflows.find(workflow_id)
        end

        def selected_chat_session
          return @selected_chat_session if defined?(@selected_chat_session)
          return @selected_chat_session = selected_candidate_chat_session if selected_candidate

          @selected_chat_session = nil
        end

        def session_attributes
          if selected_candidate
            return {
              workflow: selected_workflow,
              chat_session: selected_chat_session,
              name: terminal_session_params[:name].presence || selected_candidate.fetch(:label),
              working_directory: selected_candidate.fetch(:working_directory),
              worker_hostname: selected_candidate[:worker_hostname],
              worker_storage_key: selected_candidate[:worker_storage_key],
              queue_name: selected_candidate[:queue_name],
              workspace_kind: selected_candidate.fetch(:kind)
            }
          end

          {
            workflow: selected_workflow,
            chat_session: nil,
            name: terminal_session_params[:name].presence || selected_workflow&.slug || "Scratch",
            working_directory: working_directory,
            worker_hostname: selected_workflow&.worker_hostname,
            worker_storage_key: selected_workflow&.worker_storage_key,
            queue_name: selected_workflow&.runs&.order(created_at: :desc)&.first&.resume_worker_queue,
            workspace_kind: selected_workflow ? "workflow" : "scratch"
          }
        end

        def selected_candidate_workflow
          workflow_id = selected_candidate[:workflow_id]
          return if workflow_id.blank?

          Current.user.workflows.find(workflow_id)
        end

        def selected_candidate_chat_session
          chat_id = selected_candidate[:chat_session_id]
          return if chat_id.blank?

          Current.user.accessible_chat_sessions.active.find(chat_id)
        end

        def working_directory
          if selected_workflow
            WorkflowWorkspace.path_for(selected_workflow).to_s
          elsif terminal_session_params[:working_directory].present?
            terminal_session_params[:working_directory]
          else
            Rails.root.to_s
          end
        end

        def terminal_session_params
          return params.permit(:candidate_key, :workflow_id, :working_directory, :name) unless params[:terminal_session].is_a?(ActionController::Parameters)

          params.require(:terminal_session).permit(:candidate_key, :workflow_id, :working_directory, :name)
        end
      end
    end
  end
end
