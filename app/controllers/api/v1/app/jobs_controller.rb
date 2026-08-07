require "net/http"

module Api
  module V1
    module App
      class JobsController < BaseController
        def index
          jobs = Current.user.jobs
                             .without_active_workflows
                             .includes(:epic, :repository, :runs, :deployment_stage_statuses, workflows: { steps: :runs })
                             .order(updated_at: :desc, id: :desc)
          jobs = filter_jobs(jobs)
          limit = params.fetch(:limit, 20).to_i.clamp(1, 100)

          render json: {
            count: jobs.count,
            jobs: jobs.limit(limit).map { |job| compact_job_json(job) }
          }
        end

        def graph
          smart_folder = graph_smart_folder("job")
          url_filter = Jobs::Filter.from_params(params, user: Current.user)
          scope = Jobs::Filter.from_params(
            params,
            smart_folder: url_filter.active? ? nil : smart_folder,
            user: Current.user
          ).apply(Current.user.jobs)
          job_attrs = scope.pluck(:id, :issue_title, :state, :epic_id)
          job_ids = job_attrs.map(&:first)

          dependency_rows = JobDependency.resolved
            .where(job_id: job_ids, depends_on_job_id: job_ids)
            .pluck(:job_id, :depends_on_job_id)

          nodes = job_attrs.map do |id, title, state, epic_id|
            slug = ::App::Presentation.job_slug(id)
            {
              id: "job_#{id}",
              kind: "job",
              label: "#{slug} #{title}",
              state: state.to_s,
              epic_id: epic_id,
              url: "/jobs/#{slug}",
              is_focal: false
            }
          end

          edges = dependency_rows.map do |job_id, depends_on_job_id|
            { from_id: "job_#{depends_on_job_id}", to_id: "job_#{job_id}" }
          end

          render json: { nodes: nodes, edges: edges }
        end

        def show
          render json: ::App::JobDetailPayload.build(job: find_job, user: Current.user, params: params)
        end

        def workflows
          render json: ::App::JobDetailPayload.workflows(job: find_job, user: Current.user, params: params)
        end

        def chat_feedback
          job = find_job
          result = ChatFeedbackSubmission.call(
            job: job,
            feedback: params[:body],
            allowed_states: %w[implemented failed]
          )

          unless result.success?
            render_error("validation_failed", result.error, status: :unprocessable_content)
            return
          end

          render json: {
            job: {
              id: job.reload.id,
              state: job.state
            },
            workflow: {
              id: result.workflow.id,
              trigger_kind: result.workflow.trigger_kind,
              state: result.workflow.state
            }
          }, status: :created
        end

        def update_priority
          job = find_job_by_param(:job_id)
          priority = params[:priority].to_s

          unless Job::PRIORITIES.include?(priority)
            render_error("invalid_priority", "Invalid priority value.", status: :unprocessable_content)
            return
          end

          job.update!(priority: priority)
          render json: ::App::JobDetailPayload.build(job: job.reload, user: Current.user, params: params)
        end

        def update_provider_setting
          job = find_job_by_param(:job_id)
          setting = params[:job_provider_setting].to_s

          unless Job::PROVIDER_SETTINGS.include?(setting)
            render_error("invalid_provider_setting", "Invalid provider setting.", status: :unprocessable_content)
            return
          end
          if setting != "default" && !Current.user.agent_provider_configured?(setting)
            render_error("provider_not_configured", "That agent is not configured.", status: :unprocessable_content)
            return
          end

          job.switch_job_provider_setting!(setting)
          render json: ::App::JobDetailPayload.build(job: job.reload, user: Current.user, params: params)
        end

        def source
          render json: ::App::JobSourcePayload.build(job: find_job, user: Current.user, params: params)
        end

        def source_diff
          render json: ::App::JobSourceDiffPayload.build(job: find_job, user: Current.user, params: params)
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
            step_agent_diff: run.step_agent_diff,
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

        def transcript
          job = find_job
          run = job.runs.includes(:job_logs).order(created_at: :desc, id: :desc).first
          unless run
            render json: { job_id: job.id, run_id: nil, state: job.state, complete: job.closed?, lines: [] }
            return
          end

          render json: {
            job_id: job.id,
            run_id: run.id,
            state: run.state,
            complete: run.finished_at.present?,
            lines: run.job_logs.order(:sequence).map { |log| log.chunk.to_s }
          }
        end

        def diff
          job = find_job
          unless job.pr_number.present?
            render_error("no_pr", "Job does not have a pull request.", status: :unprocessable_content)
            return
          end

          client = GithubClient.for(repository: job.repository, user: Current.user)
          uri = URI("https://api.github.com/repos/#{job.repository.slug}/pulls/#{job.pr_number}")
          request = Net::HTTP::Get.new(uri)
          request["Accept"] = "application/vnd.github.diff"
          request["Authorization"] = "Bearer #{client.access_token}"
          request["User-Agent"] = GithubClient::USER_AGENT
          response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 30) do |http|
            http.request(request)
          end

          if response.is_a?(Net::HTTPSuccess)
            render json: { job_id: job.id, pr_url: ::App::Presentation.job_pr_url(job), diff: response.body.to_s }
          else
            render_error("github_error", "GitHub diff request failed: #{response.code}", status: :bad_gateway)
          end
        rescue ArgumentError
          render json: { job_id: job.id, pr_url: ::App::Presentation.job_pr_url(job), diff: nil, no_github_token: true }
        end

        private

        def filter_jobs(scope)
          if params[:repo].present?
            owner, name = params[:repo].to_s.split("/", 2)
            scope = scope.joins(:repository).where(repositories: { owner: owner, name: name })
          end
          scope = scope.where(state: params[:state]) if params[:state].present? && params[:state] != "all"
          if params[:q].present?
            pattern = "%#{ActiveRecord::Base.sanitize_sql_like(params[:q].to_s.downcase)}%"
            scope = scope.where("LOWER(issue_title) LIKE :pattern OR CAST(jobs.id AS CHAR) LIKE :pattern", pattern: pattern)
          end
          scope
        end

        def graph_smart_folder(subject_type)
          id = Integer(params[:smart_folder_id], exception: false)
          return unless id

          SmartFolder.for_subject(subject_type)
                     .where("user_id IS NULL OR user_id = ?", Current.user.id)
                     .find_by(id: id)
        end


        def compact_job_json(job)
          workflow = job.workflows.max_by { |candidate| [ candidate.finished_at.nil? ? 1 : 0, candidate.finished_at || Time.zone.at(0), candidate.id || 0 ] }
          steps = workflow&.steps&.sort_by(&:position) || []
          payload = {
            id: job.id,
            epic_id: job.epic_id,
            epic_title: job.epic&.title,
            state: job.state,
            summary_state: ::App::Presentation.job_summary_state(job),
            title: job.issue_title.to_s,
            issue_title: job.issue_title.to_s,
            agent_provider: job.workflow_agent_provider,
            job_provider_setting: job.job_provider_setting,
            provider_availability: ::App::ProviderAvailability.for_user(Current.user, job.workflow_agent_provider),
            repository_id: job.repository_id,
            repository_slug: job.repository.slug,
            branch_name: job.branch_name,
            pr_number: job.pr_number,
            pr_url: ::App::Presentation.job_pr_url(job),
            created_at: job.created_at&.iso8601,
            updated_at: job.updated_at&.iso8601,
            started_at: job.started_at&.iso8601,
            finished_at: job.finished_at&.iso8601,
            current_step: ::App::Presentation.current_step_caption(job),
            latest_run_id: job.runs.max_by { |run| run.created_at || Time.zone.at(0) }&.id,
            needs_attention: job.needs_attention?,
            needs_attention_reason: job.needs_attention_reason,
            workflow: workflow && {
              id: workflow.id,
              state: workflow.state,
              steps: steps.map { |step| compact_step_json(step) }
            }
          }

          if deployment_stages_configured?(job.repository)
            payload[:latest_deployment_stage] = ::App::DeploymentStageSummary.for(
              job,
              stages: deployment_stages_for(job.repository)
            )
          end

          payload
        end

        def deployment_stages_configured?(repository)
          deployment_stages_for(repository).any?
        end

        def deployment_stages_for(repository)
          @deployment_stages_by_repository_id ||= {}
          @deployment_stages_by_repository_id.fetch(repository.id) do
            @deployment_stages_by_repository_id[repository.id] = RepoDeploymentStagesReader.for_repository(repository).stages
          end
        end

        def compact_step_json(step)
          run = step.runs.max_by { |candidate| candidate.created_at || Time.zone.at(0) }
          {
            id: step.id,
            kind: step.kind,
            display_name: Step::Kind.label_for(step.kind),
            state: step.state,
            started_at: step.started_at&.iso8601,
            finished_at: step.finished_at&.iso8601,
            run_id: run&.id,
            run_state: run&.state
          }
        end

        def find_job
          find_job_by_param(:id)
        end

        def find_job_by_param(key)
          scope = Current.user.jobs
                              .includes(
                                :repository,
                                :epic,
                                :scheduled_task,
                                :owner_user,
                                :claimed_by_user,
                                :tags,
                                job_attachments: { file_attachment: :blob },
                                dependencies: [ :created_by_user, depends_on_job: :repository ],
                                dependent_links: [ job: :repository ]
                              )
          find_job_by_ref(scope, params[key])
        end
      end
    end
  end
end
