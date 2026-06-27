module Api
  module V1
    module App
      class TerminalSessionsController < BaseController
        before_action :require_terminal_feature

        def index
          sessions = Current.user.terminal_sessions.running.order(started_at: :desc)

          render json: sessions.map { |session| ::App::TerminalSessionSerializer.render(session) }
        end

        def create
          workflow = find_workflow
          session = Current.user.terminal_sessions.create!(
            workflow: workflow,
            name: session_name(workflow),
            working_directory: working_directory(workflow),
            started_at: Time.current
          )

          TerminalSessionJob.perform_later(session.id)

          render json: ::App::TerminalSessionSerializer.render(session), status: :created
        end

        def show
          render json: ::App::TerminalSessionSerializer.render(find_session)
        end

        def kill
          session = find_session
          session.update!(finished_at: Time.current, outcome: "killed")

          render json: ::App::TerminalSessionSerializer.render(session)
        end

        private

        def require_terminal_feature
          head :not_found unless Feature.terminal_enabled?
        end

        def find_session
          Current.user.terminal_sessions.find(params[:id])
        end

        def find_workflow
          return if params[:workflow_id].blank?

          Current.user.workflows.find(params[:workflow_id])
        end

        def session_name(workflow)
          name = params[:name].to_s.strip
          return name if name.present?
          return "Workflow #{workflow.id}" if workflow

          "Terminal #{Time.current.strftime("%Y-%m-%d %H:%M")}"
        end

        def working_directory(workflow)
          path = params[:working_directory].to_s.strip
          return path if path.present?
          return WorkflowWorkspace.path_for(workflow).to_s if workflow

          ENV.fetch("SYRUS_DATA_ROOT", "~/.syrus")
        end
      end
    end
  end
end
