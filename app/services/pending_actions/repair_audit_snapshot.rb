module PendingActions
  class RepairAuditSnapshot
    ARTIFACT_KEYS = %w[
      pr_title
      pr_body
      summary
      test_plan
      prepare_failure
      branch_divergence
      rebase_result
      grader_results
    ].freeze

    def self.capture(jobs)
      new(Array(jobs).compact.uniq).capture
    end

    def initialize(jobs)
      @jobs = jobs
    end

    def capture
      {
        "captured_at" => Time.current.iso8601,
        "jobs" => @jobs.map { |job| job_snapshot(job.reload) }
      }
    end

    private

    def job_snapshot(job)
      workflow = job.workflows.order(created_at: :desc, id: :desc).includes(steps: :runs).first

      {
        "id" => job.id,
        "slug" => job.slug,
        "state" => job.state,
        "validity" => job.validity,
        "closure_reason" => job.closure_reason,
        "repository_id" => job.repository_id,
        "repository_slug" => job.repository&.slug,
        "pr" => pr_snapshot(job),
        "mergeability" => mergeability_snapshot(job),
        "dependencies" => dependencies_snapshot(job),
        "landing_blocker" => landing_blocker_snapshot(job),
        "workflow" => workflow && workflow_snapshot(workflow)
      }
    end

    def pr_snapshot(job)
      {
        "number" => job.pr_number,
        "external_number" => job.external_pr_number,
        "repository_id" => job.pr_repository_id || job.repository_id,
        "head_sha" => job.mergeability_head_sha || job.pr_checks_sha,
        "base_sha" => job.mergeability_base_sha,
        "base_ref" => job.mergeability_base_ref,
        "check_state" => job.pr_checks_state,
        "checks_sha" => job.pr_checks_sha,
        "checks_checked_at" => iso8601(job.pr_checks_checked_at)
      }
    end

    def mergeability_snapshot(job)
      {
        "pr_mergeable" => job.pr_mergeable,
        "pr_mergeable_checked_at" => iso8601(job.pr_mergeable_checked_at),
        "github_mergeable" => job.github_mergeable,
        "github_mergeable_state" => job.github_mergeable_state,
        "mergeability_checked_at" => iso8601(job.mergeability_checked_at),
        "local_mergeable" => job.local_mergeable,
        "local_mergeable_state" => job.local_mergeable_state,
        "local_mergeability_checked_at" => iso8601(job.local_mergeability_checked_at)
      }
    end

    def dependencies_snapshot(job)
      {
        "overridden_at" => iso8601(job.dependencies_overridden_at),
        "overridden_by_user_id" => job.dependencies_overridden_by_user_id,
        "dependencies" => job.dependencies.order(:id).map do |dependency|
          {
            "id" => dependency.id,
            "depends_on_job_id" => dependency.depends_on_job_id,
            "depends_on_epic_id" => dependency.depends_on_epic_id,
            "source" => dependency.source
          }
        end,
        "unsatisfied_dependency_ids" => job.unsatisfied_dependencies.map(&:id)
      }
    end

    def landing_blocker_snapshot(job)
      {
        "landing_failure_reason" => job.landing_failure_reason,
        "needs_attention" => job.needs_attention,
        "needs_attention_reason" => job.needs_attention_reason,
        "landing_queue_blocked_reason" => job.landing_queue_blocked_reason
      }
    end

    def workflow_snapshot(workflow)
      {
        "id" => workflow.id,
        "trigger_kind" => workflow.trigger_kind,
        "state" => workflow.state,
        "started_at" => iso8601(workflow.started_at),
        "finished_at" => iso8601(workflow.finished_at),
        "steps" => workflow.steps.map { |step| step_snapshot(step) },
        "runs" => workflow.steps.flat_map(&:runs).map { |run| run_snapshot(run) },
        "artifacts" => workflow.artifacts.to_h.slice(*ARTIFACT_KEYS)
      }
    end

    def step_snapshot(step)
      {
        "id" => step.id,
        "kind" => step.kind,
        "state" => step.state,
        "position" => step.position,
        "iteration" => step.iteration
      }
    end

    def run_snapshot(run)
      {
        "id" => run.id,
        "step_id" => run.step_id,
        "state" => run.state,
        "trigger_kind" => run.trigger_kind,
        "started_at" => iso8601(run.started_at),
        "finished_at" => iso8601(run.finished_at),
        "head_sha" => run.head_sha
      }
    end

    def iso8601(value)
      value&.iso8601
    end
  end
end
