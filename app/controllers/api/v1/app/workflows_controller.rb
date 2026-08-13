module Api
  module V1
    module App
      class WorkflowsController < BaseController
        def coverage_hit_map
          workflow = find_workflow
          file = params[:file].to_s.strip

          unless workflow.coverage_hit_map.attached?
            render json: { hit_map_attached: false, file: file, lines: {} }
            return
          end

          begin
            full_map = workflow.coverage_hit_map_data
          rescue => e
            Rails.logger.warn("[WorkflowsController] Failed to decompress hit map for Workflow ##{workflow.id}: #{e.class}: #{e.message}")
            render json: { hit_map_attached: false, file: file, lines: {} }
            return
          end

          lines = file.present? ? (full_map[file] || {}) : {}

          render json: {
            hit_map_attached: true,
            file: file,
            lines: lines
          }
        end

        def visual_artifact
          workflow = find_workflow
          attachment = workflow.visual_artifact_for(params[:type].to_s.strip)
          raise ActiveRecord::RecordNotFound, "Visual artifact not found" unless attachment

          send_data(
            attachment.download,
            filename: attachment.filename.to_s,
            type: attachment.content_type || "application/octet-stream",
            disposition: "inline"
          )
        end

        private

        def find_workflow
          workflow = Workflow.joins(:job).where(jobs: { user_id: Current.user.id }).find(params[:workflow_id])
          workflow
        end
      end
    end
  end
end
