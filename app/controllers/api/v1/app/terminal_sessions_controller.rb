module Api
  module V1
    module App
      class TerminalSessionsController < BaseController
        def index
          return render_terminal_disabled unless Feature.terminal_enabled?

          render json: sessions_payload
        end

        def create
          return render_terminal_disabled unless Feature.terminal_enabled?

          session = TerminalSession.create!(
            user: Current.user,
            workflow: selected_workflow,
            name: session_name,
            working_directory: working_directory,
            auth_token: SecureRandom.hex(32),
            started_at: Time.current
          )
          TerminalSessionJob.perform_later(session.id)

          render json: { session: session_json(session) }, status: :created
        end

        def destroy
          return render_terminal_disabled unless Feature.terminal_enabled?

          session = TerminalSession.where(user: Current.user).find(params[:id])
          session.update!(finished_at: Time.current, outcome: "killed") if session.running?

          render json: { session: session_json(session) }
        end

        private

        def sessions_payload
          {
            sessions: TerminalSession.where(user: Current.user).running.order(started_at: :desc).map { |session| session_json(session) },
            workspaces: workspace_json
          }
        end

        def session_json(session)
          {
            id: session.id,
            name: session.name,
            working_directory: session.working_directory,
            started_at: session.started_at.iso8601,
            finished_at: session.finished_at&.iso8601,
            outcome: session.outcome,
            workflow_id: session.workflow_id
          }
        end

        def workspace_json
          scratch = {
            id: nil,
            label: "Scratch",
            working_directory: Rails.root.to_s,
            kind: "scratch"
          }
          workflows = Workflow
            .where(user: Current.user)
            .includes(job: :repository)
            .order(created_at: :desc)
            .limit(10)
            .map do |workflow|
              {
                id: workflow.id,
                label: "#{workflow.slug} - #{workflow.job.title}",
                working_directory: WorkflowWorkspace.path_for(workflow).to_s,
                kind: "workflow"
              }
            end

          [scratch, *workflows]
        end

        def selected_workflow
          return @selected_workflow if defined?(@selected_workflow)

          workflow_id = terminal_session_params[:workflow_id]
          return @selected_workflow = nil if workflow_id.blank?

          @selected_workflow = Workflow.where(user: Current.user).find(workflow_id)
        end

        def working_directory
          if selected_workflow
            WorkflowWorkspace.path_for(selected_workflow).to_s
          else
            Rails.root.to_s
          end
        end

        def session_name
          terminal_session_params[:name].presence || selected_workflow&.slug || "Scratch"
        end

        def terminal_session_params
          params.require(:terminal_session).permit(:workflow_id, :working_directory, :name)
        end

        def render_terminal_disabled
          render_error("terminal_disabled", "Terminal is not enabled.", status: :not_found)
        end
      end
    end
  end
end
