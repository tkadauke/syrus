module Api
  module V1
    module App
      class TargetGraphsController < BaseController
        include RepositoryTabsSerialization

        def repository
          repository = Repository.accessible_to(Current.user).find(params[:repository_id] || params[:id])
          response = ::App::TargetGraphPayload.for_repository(repository: repository, user: Current.user, params: params)
          return unless target_graph_stale?(response)

          render json: response.payload.merge(tabs: repository_tabs_json(repository))
        end

        def job
          job = find_job_by_ref(Job.visible_to(Current.user).includes(:repository), params[:job_id])
          workflow = workflow_for(job)
          raise ActiveRecord::RecordNotFound, "Workflow not found" unless workflow

          render_target_graph(::App::TargetGraphPayload.for_workflow(workflow: workflow, params: params))
        end

        def workflow
          workflow = Workflow.joins(:job)
                             .merge(Job.visible_to(Current.user))
                             .includes(job: :repository)
                             .find(params[:workflow_id])
          render_target_graph(::App::TargetGraphPayload.for_workflow(workflow: workflow, params: params))
        end

        private

        def render_target_graph(response)
          return unless target_graph_stale?(response)

          render json: response.payload
        end

        def target_graph_stale?(response)
          response.cache_key.blank? || stale?(etag: response.cache_key, public: false)
        end

        def workflow_for(job)
          workflow_id = params[:workflow_id].presence
          return job.workflows.find(workflow_id) if workflow_id

          job.latest_workflow
        end
      end
    end
  end
end
