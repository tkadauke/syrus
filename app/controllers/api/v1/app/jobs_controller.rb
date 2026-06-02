module Api
  module V1
    module App
      class JobsController < BaseController
        def show
          render json: ::App::JobDetailPayload.build(job: find_job, user: Current.user, params: params)
        end

        def source
          render json: ::App::JobSourcePayload.build(job: find_job, user: Current.user, params: params)
        end

        def timeline
          unless Current.user&.admin?
            render_error("forbidden", "Admin access required.", status: :forbidden)
            return
          end

          render json: ::App::JobDetailPayload.timeline(job: find_job)
        end

        def run_artifacts
          job = find_job_by_param(:job_id)
          run = job.runs.includes(:job_logs).find_by(id: params[:run_id])
          unless run
            render_error("not_found", "Run not found.", status: :not_found)
            return
          end

          logs = run.job_logs.order(:sequence).map do |log|
            {
              id: log.id,
              sequence: log.sequence,
              kind: log.kind,
              chunk: log.chunk,
              created_at: log.created_at&.iso8601
            }
          end

          render json: {
            job_id: job.id,
            run_id: run.id,
            agent_diff: run.agent_diff,
            agent_diff_bytes: run.agent_diff&.bytesize || 0,
            logs_count: logs.size,
            logs: logs
          }
        end

        def grade_log
          job = find_job_by_param(:job_id)
          run = job.runs.includes(:step).find_by(id: params[:run_id])
          unless run && %w[grade grader grader_collect].include?(run.step&.kind)
            render_error("not_found", "Grade log is not available for this run.", status: :not_found)
            return
          end

          contents = WorkflowWorkspace.grade_log_for(run, params[:name].to_s)
          unless contents
            render_error(
              "not_found",
              "Grade log is no longer available. The workflow workspace may have been pruned.",
              status: :not_found
            )
            return
          end

          render json: {
            job_id: job.id,
            run_id: run.id,
            name: params[:name].to_s,
            contents: contents
          }
        end

        private

        def find_job
          find_job_by_param(:id)
        end

        def find_job_by_param(key)
          Current.user.jobs
                      .includes(
                        :repository,
                        :tags,
                        job_attachments: { file_attachment: :blob },
                        dependencies: [ :created_by_user, depends_on_job: :repository ],
                        dependent_links: [ job: :repository ],
                        runs: [ :job_logs, :run_health_snapshots, :claude_session, :run_diagnostic ]
                      )
                      .find(params[key])
        end
      end
    end
  end
end
