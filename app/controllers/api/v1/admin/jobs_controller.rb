module Api
  module V1
    module Admin
      # Single-shot Job state dump — collapses the "write a Rails
      # runner that joins Job + Workflows + Steps + Runs +
      # diagnostics + claude_session" investigation pattern into
      # one HTTP call.
      #
      # GET /api/v1/admin/jobs/:id → JSON
      class JobsController < BaseController
        # Compact list. Filter via:
        #   ?pr_number=N
        #   ?issue_number=N
        #   ?repo=owner/name
        #   ?state=open|closed
        #   ?user=substring         — match User#email_address
        #   ?failed_in_last_24h=true — Jobs whose latest workflow ended `failed`
        #                              within the last 24h. "What just broke?"
        #   ?has_active_workflow=true — Jobs with a queued/running workflow.
        #                               "What's still in flight?"
        # No filters → most-recently updated 50. Always includes the
        # Job ID so callers can drill into `/api/v1/admin/jobs/:id`
        # for the full nested state.
        def index
          scope = Job.includes(:repository).order(updated_at: :desc)
          scope = scope.where(pr_number: params[:pr_number])       if params[:pr_number].present?
          scope = scope.where(issue_number: params[:issue_number]) if params[:issue_number].present?
          scope = scope.where(state: params[:state])               if params[:state].present?
          if params[:repo].present?
            owner, name = params[:repo].split("/", 2)
            scope = scope.joins(:repository).where(repositories: { owner: owner, name: name })
          end
          if params[:user].present?
            scope = scope.joins(:user).where("users.email_address LIKE ?", "%#{params[:user]}%")
          end
          if truthy?(params[:has_active_workflow])
            scope = scope.where(id: Workflow.active.select(:job_id))
          end
          if truthy?(params[:failed_in_last_24h])
            scope = scope.where(id: failed_recently_job_ids(24.hours.ago))
          end
          jobs = scope.limit(50)
          render json: {
            count: jobs.size,
            jobs:  jobs.map { |j| serialize_compact(j) }
          }
        end

        def show
          job = Job.includes(workflows: { steps: :runs }).find(params[:id])
          render json: serialize(job)
        end

        private

        # `?has_active_workflow=true` etc. — accept the canonical
        # truthy strings and ignore the rest (don't raise on a typo).
        def truthy?(value)
          %w[ true 1 yes ].include?(value.to_s.downcase)
        end

        # Job IDs whose MOST RECENTLY CREATED workflow ended in
        # `failed` within `cutoff`. We can't just `joins(:workflows)
        # .where(workflows: { state: "failed" })` — that matches if
        # ANY workflow failed, including ones the operator already
        # retried successfully. The "what just broke?" question
        # cares about whether the *latest* attempt is currently
        # broken. Subquery + DISTINCT ON-style in Rails (window
        # function) keeps it to one Workflow per Job.
        def failed_recently_job_ids(cutoff)
          # Latest Workflow per Job in the window. Use a subquery to
          # rank workflows by created_at DESC within their job, then
          # filter to rank=1 + state=failed + finished within cutoff.
          ranked = Workflow.select("job_id, state, finished_at,
                                    ROW_NUMBER() OVER (PARTITION BY job_id ORDER BY created_at DESC) AS rn")
          Workflow.from("(#{ranked.to_sql}) wfs")
                  .where("wfs.rn = 1 AND wfs.state = 'failed' AND wfs.finished_at >= ?", cutoff)
                  .pluck("wfs.job_id")
        end

        def serialize_compact(job)
          {
            id:             job.id,
            state:          job.state,
            kind:           job.kind,
            priority:       job.priority,
            repository:     job.repository.slug,
            issue_number:   job.issue_number,
            pr_number:      job.pr_number,
            branch_name:    job.branch_name,
            created_at:     job.created_at,
            updated_at:     job.updated_at
          }
        end

        # Job-specific serializer. The Workflow → Step → Run subtree
        # comes from the shared `Admin::JobStateSerializer`, which is
        # also used by `Api::V1::Admin::WorkflowsController#show`.
        def serialize(job)
          {
            id: job.id,
            state: job.state,
            kind: job.kind,
            priority: job.priority,
            closure_reason: job.closure_reason,
            failure_count: job.failure_count,
            repository: { id: job.repository.id, slug: job.repository.slug, default_branch: job.repository.default_branch },
            user_email: job.user.email_address,
            issue_number: job.issue_number,
            issue_title: job.issue_title,
            branch_name: job.branch_name,
            pr_number: job.pr_number,
            external_pr_number: job.external_pr_number,
            pr_mergeable: job.pr_mergeable,
            pr_mergeable_checked_at: job.pr_mergeable_checked_at,
            scheduled_task_id: job.scheduled_task_id,
            started_at: job.started_at,
            finished_at: job.finished_at,
            workflows: job.workflows.order(:created_at).map { |wf| ::Admin::JobStateSerializer.workflow(wf) }
          }
        rescue => e
          ::Admin::JobStateSerializer.per_record_error(job, e)
        end
      end
    end
  end
end
