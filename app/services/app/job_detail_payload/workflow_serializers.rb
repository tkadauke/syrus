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

      AgentSessionSummary = Data.define(:session_id, :provider, :transcript_pruned, :transcript_bytes, :transcript_lines)
      MAX_STEPS_PER_WORKFLOW = Integer(ENV["SYRUS_JOB_DETAIL_MAX_STEPS_PER_WORKFLOW"], exception: false) || 250

      def workflows_json
        PerformanceLogging.phase("job_detail.workflows.serialize", job_id: @job.id, page: workflows_page) do
          paginated_workflows.map do |workflow|
            workflow_json(workflow)
          end
        end
      end

      def workflow_json(workflow)
        PerformanceLogging.phase("job_detail.workflow.serialize", job_id: @job.id, workflow_id: workflow.id) do
          steps = ordered_steps_for(workflow)
          step_count = step_counts_by_workflow_id.fetch(workflow.id, steps.size)
          latest_step = steps.last
          {
            id: workflow.id,
            slug: workflow.slug,
            path: App::WorkflowNavigation.path(workflow),
            trigger_kind: workflow.trigger_kind,
            agent_provider: workflow.agent_provider,
            state: workflow.state,
            failure_count: workflow.failure_count,
            artifacts: enrich_artifacts(workflow.artifacts),
            cleaned_up_at: iso8601(workflow.cleaned_up_at),
            retry_available: workflow_retry_available?(workflow),
            started_at: iso8601(workflow.started_at),
            finished_at: iso8601(workflow.finished_at),
            created_at: iso8601(workflow.created_at),
            updated_at: iso8601(workflow.updated_at),
            app_retry_step_path: "/api/v1/app/jobs/#{@job.id}/workflows/#{workflow.id}/retry_step",
            app_push_commits_path: "/api/v1/app/jobs/#{@job.id}/workflows/#{workflow.id}/push_commits",
            app_force_push_branch_path: "/api/v1/app/jobs/#{@job.id}/workflows/#{workflow.id}/force_push_branch",
            app_discard_branch_output_path: "/api/v1/app/jobs/#{@job.id}/workflows/#{workflow.id}/discard_branch_output",
            failure_classification: workflow_failure_classification_json(workflow),
            steps_total: step_count,
            steps_displayed: steps.size,
            steps_truncated: step_count > steps.size,
            steps: PerformanceLogging.phase("job_detail.workflow.steps", job_id: @job.id, workflow_id: workflow.id, step_count: steps.size) do
              steps.map { |step| step_json(step, workflow: workflow, latest_step: latest_step) }
            end
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
        @paginated_workflows ||= PerformanceLogging.phase("job_detail.workflows.query", job_id: @job.id, page: workflows_page) do
          workflows_scope
            .offset((workflows_page - 1) * WORKFLOWS_PER_PAGE)
            .limit(WORKFLOWS_PER_PAGE)
            .to_a
        end
      end

      def workflows_scope
        @job.workflows
            .reorder(created_at: :desc, id: :desc)
      end

      def total_workflows
        @total_workflows ||= PerformanceLogging.phase("job_detail.workflows.total", job_id: @job.id) { @job.workflows.count }
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

      def ordered_steps_for(workflow)
        steps_by_workflow_id.fetch(workflow.id, [])
      end

      def steps_by_workflow_id
        @steps_by_workflow_id ||= PerformanceLogging.phase("job_detail.workflow.steps.query", job_id: @job.id, workflow_count: paginated_workflows.size) do
          ids = paginated_workflows.map(&:id)
          next {} if ids.empty?

          steps = Step
            .where(workflow_id: ids)
            .order(:workflow_id, :position, :id)
            .to_a

          grouped = steps.group_by(&:workflow_id)
          ids.to_h do |workflow_id|
            [ workflow_id, grouped.fetch(workflow_id, []).last(MAX_STEPS_PER_WORKFLOW) ]
          end
        end
      end

      def step_counts_by_workflow_id
        @step_counts_by_workflow_id ||= begin
          ids = paginated_workflows.map(&:id)
          ids.empty? ? {} : Step.where(workflow_id: ids).group(:workflow_id).count
        end
      end

      def ordered_runs_for(step)
        runs_by_step_id.fetch(step.id, [])
      end

      def ordered_command_spans_for(run)
        command_spans_by_run_id.fetch(run.id, [])
      end

      def warnings_for(step)
        workflow_warnings_by_step_id.fetch(step.id, [])
      end

      def workflow_warnings_by_step_id
        @workflow_warnings_by_step_id ||= PerformanceLogging.phase("job_detail.workflow.warnings.query", job_id: @job.id, step_count: visible_step_ids.size) do
          ids = visible_step_ids
          next {} if ids.empty?

          WorkflowWarning.where(step_id: ids).order(:step_id, :created_at, :id).group_by(&:step_id)
        end
      end

      # Generic — driven entirely by kind/title/evidence/suggested_prompt so
      # new WorkflowWarning kinds render on the Job details page with zero
      # new backend or frontend code. See config/syrus_docs/workflow_warnings.md.
      def workflow_warning_json(warning)
        {
          id: warning.id,
          kind: warning.kind,
          severity: warning.severity,
          title: warning.redacted_title,
          evidence: warning.redacted_evidence,
          suggested_prompt: warning.redacted_suggested_prompt,
          state: warning.state,
          created_job_id: warning.created_job_id,
          created_at: iso8601(warning.created_at)
        }
      end

      def step_json(step, workflow:, latest_step:)
        PerformanceLogging.phase("job_detail.step.serialize", job_id: @job.id, workflow_id: workflow.id, step_id: step.id, kind: step.kind) do
          runs = ordered_runs_for(step)
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
            warnings: warnings_for(step).map { |warning| workflow_warning_json(warning) },
            latest: step == latest_step,
            runs: PerformanceLogging.phase("job_detail.step.runs", job_id: @job.id, workflow_id: workflow.id, step_id: step.id, run_count: runs.size) do
              runs.map { |run| run_json(run, workflow: workflow, step: step) }
            end
          }
        end
      end

      def step_display_name(step)
        return step.details["name"].presence || step.details["command"].presence || "grader" if step.kind == "grader"

        Step::Kind.label_for(step.kind)
      end

      def step_display_status(step)
        active_run = ordered_runs_for(step).find { |run| run.state.in?(%w[queued running]) }
        return active_run.state if active_run
        return nil if step.queued? && ordered_runs_for(step).empty?

        step.state
      end

      def run_json(run, workflow:, step:)
        session = agent_session_summary_for(run)
        command_spans = PerformanceLogging.phase("job_detail.run.command_spans", job_id: @job.id, run_id: run.id) do
          ordered_command_spans_for(run).map { |span| command_span_json(span) }
        end
        agent_diff_bytes = projected_byte_size(run, "agent_diff")
        step_agent_diff_bytes = projected_byte_size(run, "step_agent_diff")
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
          skill_source: run.skill_source,
          skill_resolved_path: run.skill_resolved_path,
          skill_resolved_class: run.skill_resolved_class,
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
          agent_diff_present: agent_diff_bytes.positive?,
          agent_diff_bytes: agent_diff_bytes,
          step_agent_diff_present: step_agent_diff_bytes.positive?,
          step_agent_diff_bytes: step_agent_diff_bytes,
          job_log_count: job_log_stats.fetch(run.id, EMPTY_JOB_LOG_STATS)[:count],
          rate_limited: job_log_stats.fetch(run.id, EMPTY_JOB_LOG_STATS)[:rate_limited],
          failure_classification: failure_classification_json(run.run_failure_classification),
          run_diagnostic: run_diagnostic_json(run.run_diagnostic),
          health_snapshots: latest_health_snapshot_for(run).then { |snapshot| snapshot ? [ health_snapshot_json(snapshot) ] : [] },
          active_process: active_process_json(run),
          command_spans: command_spans,
          agent_session: agent_session_json(session),
          can_stop: run.may_cancel?,
          can_diagnose: run.queued? || run.running?,
          can_resume: %w[failed cancelled].include?(run.state) && session.present? && !job_has_active_run?,
          app_artifacts_path: "/api/v1/app/jobs/#{@job.id}/runs/#{run.id}/artifacts",
          app_stop_path: "/api/v1/app/jobs/#{@job.id}/runs/#{run.id}/stop",
          app_diagnose_path: "/api/v1/app/jobs/#{@job.id}/runs/#{run.id}/diagnose",
          app_resume_path: "/api/v1/app/jobs/#{@job.id}/resume",
          app_grade_log_path: app_grade_log_path(run, workflow: workflow, step: step)
        }
      end

      def active_process_json(run)
        process = active_processes_by_run_id[run.id]
        return unless process

        {
          id: process.id,
          kind: process.kind,
          command: process.redacted_command,
          workdir: process.workdir,
          hostname: process.hostname,
          pid: process.pid,
          started_at: iso8601(process.started_at),
          last_heartbeat_at: iso8601(process.last_chunk_at),
          wall_timeout_s: process.wall_timeout_s,
          silent_timeout_s: process.silent_timeout_s
        }
      end

      def command_span_json(span)
        {
          id: span.id,
          run_id: span.run_id,
          job_id: span.job_id,
          workflow_id: span.workflow_id,
          step_id: span.step_id,
          spawned_process_id: span.spawned_process_id,
          sequence: span.sequence,
          name: span.name,
          command_excerpt: CommandRedactor.redact(span.command_excerpt),
          started_at: iso8601(span.started_at),
          finished_at: iso8601(span.finished_at),
          duration_ms: span.duration_ms,
          duration_s: span.duration_s,
          exit_status: span.exit_status,
          outcome: span.outcome,
          hostname: span.hostname,
          metadata: CommandRedactor.redact_value(span.metadata),
          sample_count: 0,
          samples_missing: true,
          retention_limited: false,
          summary: {},
          pressure: {
            level: "unknown",
            reasons: [ "worker health correlation is loaded on demand" ]
          }
        }
      end

      def workflow_failure_classification_json(workflow)
        failure_classification_json(workflow_failure_classifications_by_workflow_id[workflow.id])
      end

      def workflow_artifacts_json(workflow)
        artifacts = workflow.artifacts
        return artifacts unless artifacts.is_a?(Hash)

        artifacts.slice(
          "adversarial_review_iterations",
          "visual_review_iterations",
          "auto_rebase_reason",
          "auto_rebase_result",
          "branch_divergence",
          "branch_divergence_recovery",
          "branch_divergence_recovery_error",
          "branch_divergence_recovery_pending",
          "chat_feedback",
          "feedback_source",
          "no_pr_reason",
          "pr_body",
          "pr_title",
          "summary",
          "test_plan"
        ).tap do |safe|
          safe["coverage"] = coverage_artifact_json(artifacts["coverage"]) if artifacts["coverage"].is_a?(Hash)
        end
      end

      def coverage_artifact_json(coverage)
        coverage.slice(
          "coverage_unavailable",
          "files",
          "hit_map_attached",
          "pr_delta",
          "sources_status",
          "summary",
          "threshold_miss",
          "threshold_miss_details"
        )
      end

      def visible_run_ids
        @visible_run_ids ||= paginated_workflows.flat_map do |workflow|
          ordered_steps_for(workflow).flat_map { |step| ordered_runs_for(step).map(&:id) }
        end.compact
      end

      def visible_step_ids
        @visible_step_ids ||= paginated_workflows.flat_map do |workflow|
          ordered_steps_for(workflow).map(&:id)
        end.compact
      end

      def runs_by_step_id
        @runs_by_step_id ||= PerformanceLogging.phase("job_detail.workflow.runs.query", job_id: @job.id, step_count: visible_step_ids.size) do
          ids = visible_step_ids
          next {} if ids.empty?

          Run
            .where(step_id: ids)
            .select(
              :id,
              :job_id,
              :step_id,
              :state,
              :trigger_kind,
              :agent_provider,
              :agent_outcome,
              :agent_turns,
              :agent_pr_title,
              :agent_summary,
              :parent_session_id,
              :skill_source,
              :skill_resolved_path,
              :skill_resolved_class,
              :head_sha,
              :iteration,
              :started_at,
              :last_heartbeat_at,
              :finished_at,
              :created_at,
              :updated_at,
              :cost_usd,
              :input_tokens,
              :output_tokens,
              :cache_creation_input_tokens,
              :cache_read_input_tokens,
              Arel.sql("LENGTH(runs.agent_diff) AS agent_diff_byte_size"),
              Arel.sql("LENGTH(runs.step_agent_diff) AS step_agent_diff_byte_size")
            )
            .includes(:run_diagnostic, :run_failure_classification)
            .order(:step_id, :created_at, :id)
            .group_by(&:step_id)
        end
      end

      def latest_health_snapshot_for(run)
        latest_health_snapshots_by_run_id[run.id]
      end

      def latest_health_snapshots_by_run_id
        @latest_health_snapshots_by_run_id ||= begin
          ids = visible_run_ids
          if ids.empty?
            {}
          else
            latest_ids = RunHealthSnapshot.where(run_id: ids).group(:run_id).maximum(:id).values
            latest_ids.empty? ? {} : RunHealthSnapshot.where(id: latest_ids).index_by(&:run_id)
          end
        end
      end

      def active_processes_by_run_id
        @active_processes_by_run_id ||= begin
          ids = visible_run_ids
          if ids.empty?
            {}
          else
            SpawnedProcess.where(run_id: ids, finished_at: nil)
                          .order(:run_id, started_at: :asc, id: :asc)
                          .each_with_object({}) { |process, memo| memo[process.run_id] = process }
          end
        end
      end

      def command_spans_by_run_id
        @command_spans_by_run_id ||= begin
          ids = visible_run_ids
          if ids.empty?
            {}
          else
            CommandSpan.where(run_id: ids).order(:run_id, :sequence, :id).group_by(&:run_id)
          end
        end
      end

      def agent_session_summary_for(run)
        agent_session_summaries_by_run_id[run.id]
      end

      def agent_session_summaries_by_run_id
        @agent_session_summaries_by_run_id ||= begin
          ids = visible_run_ids
          if ids.empty?
            {}
          else
            ProviderSession
              .where(run_id: ids)
              .pluck(
                :run_id,
                :session_id,
                :provider,
                :transcript_pruned
              )
              .to_h do |run_id, session_id, provider, transcript_pruned|
                [
                  run_id,
                  AgentSessionSummary.new(
                    session_id: session_id,
                    provider: provider,
                    transcript_pruned: ActiveModel::Type::Boolean.new.cast(transcript_pruned),
                    transcript_bytes: nil,
                    transcript_lines: nil
                  )
                ]
              end
          end
        end
      end

      def workflow_retry_available?(workflow)
        workflow.failed? && workflow.cleaned_up_at.nil? && workflow.id == latest_workflow_id
      end

      def latest_workflow_id
        @latest_workflow_id ||= @job.workflows.maximum(:id)
      end

      def job_has_active_run?
        return @job_has_active_run if defined?(@job_has_active_run)

        @job_has_active_run = PerformanceLogging.phase("job_detail.job.any_active_run", job_id: @job.id) { @job.any_active_run? }
      end

      EMPTY_JOB_LOG_STATS = { count: 0, rate_limited: false }.freeze

      def job_log_stats
        @job_log_stats ||= begin
          ids = visible_run_ids
          if ids.empty?
            {}
          else
            JobLog.where(run_id: ids).group(:run_id, :kind).count.each_with_object({}) do |((run_id, kind), count), memo|
              stats = memo[run_id] ||= { count: 0, rate_limited: false }
              stats[:count] += count
              stats[:rate_limited] = true if kind == "rate_limited"
            end
          end
        end
      end

      def workflow_failure_classifications_by_workflow_id
        @workflow_failure_classifications_by_workflow_id ||= begin
          workflow_ids = paginated_workflows.map(&:id)
          if workflow_ids.empty?
            {}
          else
            rows = Run
              .joins(:step)
              .where(steps: { workflow_id: workflow_ids }, state: "failed")
              .select(
                :id,
                "steps.workflow_id AS workflow_id_for_failure_classification",
                Arel.sql("COALESCE(runs.finished_at, runs.updated_at, runs.created_at) AS failure_sort_at")
              )
              .order(Arel.sql("steps.workflow_id ASC, failure_sort_at DESC, runs.id DESC"))
              .to_a

            run_ids_by_workflow_id = {}
            rows.each do |run|
              workflow_id = run.read_attribute("workflow_id_for_failure_classification")
              run_ids_by_workflow_id[workflow_id] ||= run.id
            end

            classifications = RunFailureClassification.where(run_id: run_ids_by_workflow_id.values).index_by(&:run_id)
            run_ids_by_workflow_id.transform_values { |run_id| classifications[run_id] }.compact
          end
        end
      end

      def projected_byte_size(run, column)
        attribute = column == "step_agent_diff" ? "step_agent_diff_byte_size" : "agent_diff_byte_size"
        value = run.read_attribute(attribute)
        value.to_i
      rescue ActiveModel::MissingAttributeError
        run.public_send(column)&.bytesize || 0
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
          transcript_pruned: session.transcript_pruned,
          transcript_bytes: session.transcript_bytes,
          transcript_lines: session.transcript_lines
        }
      end

      ARTIFACTS_EXCLUDED_KEYS = %w[iterations].freeze
      COVERAGE_EXCLUDED_KEYS = %w[diff_annotations pr_comment_body].freeze

      # Returns a filtered, enriched artifacts hash for the detail UI.
      # Strips large/internal keys (iterations, coverage diff_annotations, etc.),
      # then injects renderer_type into typed_artifact entries.
      def enrich_artifacts(artifacts)
        return artifacts unless artifacts.is_a?(Hash)

        filtered = artifacts.except(*ARTIFACTS_EXCLUDED_KEYS)

        if filtered["coverage"].is_a?(Hash)
          filtered = filtered.merge("coverage" => filtered["coverage"].except(*COVERAGE_EXCLUDED_KEYS))
        end

        typed = filtered["typed_artifacts"]
        return filtered unless typed.is_a?(Array)

        filtered.merge("typed_artifacts" => TypedArtifactRenderer.enrich(typed))
      end

      def app_grade_log_path(run, workflow:, step: nil)
        step ||= run.step
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
