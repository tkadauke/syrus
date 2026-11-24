module Api
  module V1
    module App
      class CoverageController < BaseController
        TREND_MAX_DAYS = 365

        def trend
          repository = Repository.accessible_to(Current.user).find(params[:repository_id])
          days = params.fetch(:days, 30).to_i.clamp(1, TREND_MAX_DAYS)

          averages = SyrusCoverage::Snapshot.daily_averages(repository: repository, days: days)
          latest_snapshot = SyrusCoverage::Snapshot.where(repository: repository)
                                                   .for_project(SyrusCoverage.root_project_id)
                                                   .on_branch(repository.default_branch)
                                                   .order(created_at: :desc)
                                                   .first

          trend = averages.map do |row|
            {
              "date" => row.date.to_s,
              "lines_pct" => row.avg_lines_pct&.to_f&.round(2),
              "branches_pct" => row.avg_branches_pct&.to_f&.round(2),
              "functions_pct" => row.avg_functions_pct&.to_f&.round(2)
            }
          end

          latest = if latest_snapshot
            {
              "lines_pct" => latest_snapshot.lines_pct&.to_f,
              "branches_pct" => latest_snapshot.branches_pct&.to_f,
              "functions_pct" => latest_snapshot.functions_pct&.to_f
            }
          end

          payload = { "days" => days, "trend" => trend, "latest" => latest }
          render json: payload if stale?(etag: payload)
        end

        def hit_map
          workflow = find_workflow
          file = params[:file].to_s.strip

          begin
            full_map = SyrusCoverage::HitMap.data_for(workflow)
          rescue => e
            Rails.logger.warn("[SyrusCoverage] Failed to decompress hit map for Workflow ##{workflow.id}: #{e.class}: #{e.message}")
            render json: { hit_map_attached: false, file: file, lines: {} }
            return
          end

          if full_map.nil?
            render json: { hit_map_attached: false, file: file, lines: {} }
            return
          end

          render json: { hit_map_attached: true, file: file, lines: file.present? ? (full_map[file] || {}) : {} }
        end

        private

        def find_workflow
          readable_jobs = if Current.user.admin?
            Job.visible_to(Current.user, scope: Job.all)
          else
            Job.visible_to(Current.user, scope: Job.where(user: Current.user).or(Job.accessible_to(Current.user)))
          end
          workflow_scope = Workflow.joins(:job).merge(restrict_invocation_relation(readable_jobs))
          restrict_invocation_relation(workflow_scope).find(params[:workflow_id])
        end
      end
    end
  end
end
