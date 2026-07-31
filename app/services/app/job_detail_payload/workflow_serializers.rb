module App
  class JobDetailPayload
    module WorkflowSerializers
      extend ActiveSupport::Concern

      # Execution-graph serialization extracted from JobDetailPayload: the paginated
      # workflow list, and the per-step / per-run / process / failure-classification /
      # diagnostic / health-snapshot / agent-session JSON. Mixed back in via
      # ActiveSupport::Concern, so it reads the same @job/@user/@params, the
      # WORKFLOWS_PER_PAGE constant on the class body, and the shared iso8601 /
      # owner_json helpers through the include ancestry.

      def workflows_json
        paginated_workflows.map do |workflow|
          {
            id: workflow.id,
            slug: workflow.slug,
            path: App::WorkflowNavigation.path(workflow),
            trigger_kind: workflow.trigger_kind,
            agent_provider: workflow.agent_provider,
            state: workflow.state,
            failure_count: workflow.failure_count,
            artifacts: workflow.artifacts,
            cleaned_up_at: iso8601(workflow.cleaned_up_at),
            retry_available: workflow.retry_available?,
            started_at: iso8601(workflow.started_at),
            finished_at: iso8601(workflow.finished_at),
            created_at: iso8601(workflow.created_at),
            updated_at: iso8601(workflow.updated_at),
            app_retry_step_path: "/api/v1/app/jobs/#{@job.id}/workflows/#{workflow.id}/retry_step",
            app_push_commits_path: "/api/v1/app/jobs/#{@job.id}/workflows/#{workflow.id}/push_commits",
            app_force_push_branch_path: "/api/v1/app/jobs/#{@job.id}/workflows/#{workflow.id}/force_push_branch",
            app_discard_branch_output_path: "/api/v1/app/jobs/#{@job.id}/workflows/#{workflow.id}/discard_branch_output",
            failure_classification: workflow_failure_classification_json(workflow),
            steps: workflow.steps.order(:position).map { |step| step_json(step, workflow: workflow) }
          }
        end
      end

      def workflows_pagination_json
        total = total_workflows
        first_item = total.zero? ? 0 : ((workflows_page - 1) * WORKFLOWS_PER_PAGE) + 1
        last_item = [ workflows_page * WORKFLOWS_PER_PAGE, total ].min

        {
          page: workflows_page,
          per_page: WORKFLOWS_PER_PAGE,
          total_workflows: total,
          total_pages: total_workflow_pages,
          first_item: first_item,
          last_item: last_item,
          previous_path: workflows_page > 1 ? workflow_page_path(workflows_page - 1) : nil,
          next_path: workflows_page < total_workflow_pages ? workflow_page_path(workflows_page + 1) : nil
        }
      end

      def paginated_workflows
        @paginated_workflows ||= workflows_scope
          .offset((workflows_page - 1) * WORKFLOWS_PER_PAGE)
          .limit(WORKFLOWS_PER_PAGE)
      end

      def workflows_scope
        @job.workflows
            .includes(steps: { runs: [ :claude_session, :run_diagnostic, :run_failure_classification, :run_health_snapshots, :spawned_processes ] })
            .reorder(created_at: :desc, id: :desc)
      end

      def total_workflows
        @total_workflows ||= @job.workflows.count
      end

      def workflows_page
        @workflows_page ||= [ requested_workflows_page, total_workflow_pages ].min
      end

      def requested_workflows_page
        page = @params[:workflows_page].presence || @params["workflows_page"].presence || 1
        [ page.to_i, 1 ].max
      end

      def total_workflow_pages
        @total_workflow_pages ||= [ (total_workflows / WORKFLOWS_PER_PAGE.to_f).ceil, 1 ].max
      end

      def workflow_page_path(page)
        "#{job_path(@job)}?#{ { tab: "workflows", workflows_page: page }.to_query }"
      end

      def step_json(step, workflow:)
        {
          id: step.id,
          kind: step.kind,
          display_name: step_display_name(step),
          display_status: step_display_status(step),
          position: step.position,
          iteration: step.iteration,
          loop_id: step.loop_id,
          state: step.state,
          started_at: iso8601(step.started_at),
          finished_at: iso8601(step.finished_at),
          created_at: iso8601(step.created_at),
          updated_at: iso8601(step.updated_at),
          details: step.details.presence,
          latest: step == workflow.steps.last,
          runs: step.runs.order(:created_at).map { |run| run_json(run, workflow: workflow) }
        }
      end

      def step_display_name(step)
        return step.details["name"].presence || step.details["command"].presence || "grader" if step.kind == "grader"

        Step::Kind.label_for(step.kind)
      end

      def step_display_status(step)
        active_run = step.runs.find { |run| run.state.in?(%w[queued running]) }
        return active_run.state if active_run
        return nil if step.queued? && step.runs.empty?

        step.state
      end

      def run_json(run, workflow:)
        session = run.claude_session
        {
          id: run.id,
          state: run.state,
          trigger_kind: run.trigger_kind,
          agent_provider: run.agent_provider,
          agent_outcome: run.agent_outcome,
          agent_turns: run.agent_turns,
          agent_pr_title: run.agent_pr_title,
          agent_summary: run.agent_summary,
          parent_session_id: run.parent_session_id,
          head_sha: run.head_sha,
          iteration: run.iteration,
          started_at: iso8601(run.started_at),
          last_heartbeat_at: iso8601(run.last_heartbeat_at),
          finished_at: iso8601(run.finished_at),
          created_at: iso8601(run.created_at),
          updated_at: iso8601(run.updated_at),
          cost_usd: run.cost_usd&.to_f,
          input_tokens: run.input_tokens,
          output_tokens: run.output_tokens,
          cache_creation_input_tokens: run.cache_creation_input_tokens,
          cache_read_input_tokens: run.cache_read_input_tokens,
          agent_diff_present: run.agent_diff.present?,
          agent_diff_bytes: run.agent_diff&.bytesize || 0,
          step_agent_diff_present: run.step_agent_diff.present?,
          step_agent_diff_bytes: run.step_agent_diff&.bytesize || 0,
          job_log_count: job_log_counts.fetch(run.id, 0),
          rate_limited: rate_limited_run_ids.key?(run.id),
          failure_classification: failure_classification_json(run.run_failure_classification),
          run_diagnostic: run_diagnostic_json(run.run_diagnostic),
          health_snapshots: run.run_health_snapshots.ordered.map { |snapshot| health_snapshot_json(snapshot) },
          active_process: active_process_json(run),
          worker_health_correlation: WorkerHealthRunCorrelation.for_run(run, sample_limit: 0),
          agent_session: agent_session_json(session),
          can_stop: run.may_cancel?,
          can_diagnose: run.queued? || run.running?,
          can_resume: %w[failed cancelled].include?(run.state) && session.present?,
          app_artifacts_path: "/api/v1/app/jobs/#{@job.id}/runs/#{run.id}/artifacts",
          app_stop_path: "/api/v1/app/jobs/#{@job.id}/runs/#{run.id}/stop",
          app_diagnose_path: "/api/v1/app/jobs/#{@job.id}/runs/#{run.id}/diagnose",
          app_resume_path: "/api/v1/app/jobs/#{@job.id}/resume",
          app_grade_log_path: app_grade_log_path(run, workflow: workflow)
        }
      end

      def active_process_json(run)
        process = run.spawned_processes
                     .select { |candidate| candidate.finished_at.nil? }
                     .max_by { |candidate| candidate.started_at || candidate.created_at }
        return unless process

        {
          id: process.id,
          kind: process.kind,
          command: process.command,
          workdir: process.workdir,
          hostname: process.hostname,
          pid: process.pid,
          started_at: iso8601(process.started_at),
          last_heartbeat_at: iso8601(process.last_chunk_at),
          wall_timeout_s: process.wall_timeout_s,
          silent_timeout_s: process.silent_timeout_s
        }
      end

      def workflow_failure_classification_json(workflow)
        run = workflow.steps
                      .flat_map { |step| step.runs.select(&:failed?) }
                      .sort_by { |candidate| candidate.finished_at || candidate.updated_at || candidate.created_at }
                      .last
        failure_classification_json(run&.run_failure_classification)
      end

      def visible_run_ids
        @visible_run_ids ||= paginated_workflows.flat_map do |workflow|
          workflow.steps.flat_map { |step| step.runs.map(&:id) }
        end.compact
      end

      def job_log_counts
        @job_log_counts ||= begin
          ids = visible_run_ids
          ids.empty? ? {} : JobLog.where(run_id: ids).group(:run_id).count
        end
      end

      def rate_limited_run_ids
        @rate_limited_run_ids ||= begin
          ids = visible_run_ids
          ids.empty? ? {} : JobLog.where(run_id: ids, kind: "rate_limited").distinct.pluck(:run_id).index_with(true)
        end
      end

      def failure_classification_json(classification)
        return unless classification

        payload = {
          id: classification.id,
          classification: classification.classification,
          confidence: classification.confidence&.to_f,
          retryable: classification.retryable,
          reason: classification.reason,
          diagnostic_summary: classification.diagnostic_summary,
          classified_at: iso8601(classification.classified_at)
        }
        payload[:classifier_inputs] = classification.classifier_inputs if @user.admin?
        payload
      end

      def run_diagnostic_json(diagnostic)
        return unless diagnostic

        base = {
          id: diagnostic.id,
          present: true,
          created_at: iso8601(diagnostic.created_at)
        }
        return base unless @user.admin?

        base.merge(
          error_class: diagnostic.error_class,
          error_message: diagnostic.error_message,
          error_backtrace: diagnostic.error_backtrace,
          repo_snapshot: diagnostic.repo_snapshot,
          git_snapshot: diagnostic.git_snapshot,
          environment_snapshot: diagnostic.environment_snapshot
        )
      end

      def health_snapshot_json(snapshot)
        {
          id: snapshot.id,
          health_status: snapshot.health_status,
          hint: snapshot.hint,
          run_state: snapshot.run_state,
          heartbeat_age_seconds: snapshot.heartbeat_age_seconds,
          last_log_at: iso8601(snapshot.last_log_at),
          log_count: snapshot.log_count,
          agent_turns: snapshot.agent_turns,
          agent_diff_bytes: snapshot.agent_diff_bytes,
          head_sha: snapshot.head_sha,
          sq_job_state: snapshot.sq_job_state,
          worktree_exists: snapshot.worktree_exists,
          claude_process_running: snapshot.claude_process_running,
          branch_on_origin: snapshot.branch_on_origin,
          mcp_sidecar_alive: snapshot.mcp_sidecar_alive,
          last_log_preview: snapshot.last_log_preview,
          worktree_git_status: snapshot.worktree_git_status,
          worktree_recent_commits: snapshot.worktree_recent_commits,
          sq_error_class: snapshot.sq_error_class,
          sq_error_message: snapshot.sq_error_message,
          sq_error_backtrace: snapshot.sq_error_backtrace,
          claude_process_info: snapshot.claude_process_info,
          created_at: iso8601(snapshot.created_at)
        }
      end

      def agent_session_json(session)
        return unless session

        {
          session_id: session.session_id,
          provider: session.provider,
          transcript_pruned: session.transcript_jsonl.nil?,
          transcript_bytes: session.transcript_jsonl&.bytesize,
          transcript_lines: session.transcript_jsonl&.count("\n")
        }
      end

      def app_grade_log_path(run, workflow:)
        step = run.step
        return unless step&.kind.in?(%w[grade grader])

        name = step.details.is_a?(Hash) ? step.details["name"] : nil
        return if name.blank?

        query = { name: name, workflow_id: workflow.id }.compact.to_query
        path = "/api/v1/app/jobs/#{@job.id}/runs/#{run.id}/grade_log"
        query.present? ? "#{path}?#{query}" : path
      end
    end
  end
end
