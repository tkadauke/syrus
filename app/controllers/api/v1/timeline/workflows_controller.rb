module Api
  module V1
    module Timeline
      # GET /api/v1/timeline/workflows/:id — Step/Run waterfall for one
      # Workflow (the timeline plugin's micro drill-down view).
      class WorkflowsController < BaseController
        def show
          render json: ::Timeline::WorkflowWaterfallQuery.call(workflow_id: params[:id])
        end
      end
    end
  end
end
