module Api
  module V1
    module Admin
      # Single-shot Job state dump — collapses the "write a Rails
      # runner that joins Job + Workflows + Steps + Runs +
      # diagnostics + agent-session metadata" investigation pattern into
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
          scope = Job.includes(:repository, :owner_user).order(updated_at: :desc)
          scope = scope.where(pr_number: params[:pr_number])       if params[:pr_number].present?
          scope = scope.where(issue_number: params[:issue_number]) if params[:issue_number].present?
          if params[:state].present?
            scope = params[:state] == "open" ? scope.open_threads : scope.where(state: params[:state])
          end
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
          payload = serialize(job)
          payload[:github_pr] = github_pr_snapshot(job) if truthy?(params[:include_github])
          render json: payload
        end

        def create
          attrs = job_params
          repository = find_active_repository(attrs)
          return render_error("validation_failed", "Repository not found or not active.", status: :unprocessable_content) unless repository

          prompt_text = attrs[:prompt].to_s.strip
          return render_error("validation_failed", "Prompt can't be blank.", status: :unprocessable_content) if prompt_text.blank?

          agent_provider = attrs[:agent_provider].to_s.presence
          if agent_provider.present? && !repository.user.agent_provider_configured?(agent_provider)
            return render_error("validation_failed", "That agent is not configured for the repository owner.", status: :unprocessable_content)
          end

          priority = attrs[:priority].to_s.presence || "medium"
          unless Job::PRIORITIES.include?(priority)
            return render_error("validation_failed", "Priority must be one of: #{Job::PRIORITIES.to_sentence}.", status: :unprocessable_content)
          end

          epic = find_epic(repository, attrs[:epic_id])
          return render_error("validation_failed", "Epic not found in that repository.", status: :unprocessable_content) if attrs[:epic_id].present? && !epic

          owner_user = find_owner_user(attrs[:owner_user_id])
          return render_error("validation_failed", "Owner user not found.", status: :unprocessable_content) if attrs[:owner_user_id].present? && !owner_user

          selected_agent_provider = agent_provider || repository.effective_agent_provider
          job = repository.user.jobs.create!(
            repository: repository,
            kind: "direct",
            issue_number: nil,
            issue_title: attrs[:title].to_s.strip.presence || DirectJobTitleGenerator.call(
              prompt_text,
              user: repository.user,
              repository: repository,
              agent_provider: selected_agent_provider
            ),
            issue_body: prompt_text,
            agent_provider: selected_agent_provider,
            priority: priority,
            epic: epic,
            owner_user: owner_user
          )
          job.advance_after_triage! if job.may_advance_after_triage?

          render json: {
            message: "Direct job created.",
            job: serialize(job.reload)
          }, status: :created
        end

        private

        def job_params
          source = params[:job].present? ? params.require(:job) : params
          source.permit(:repository_id, :repository, :repo, :title, :prompt, :priority, :agent_provider, :epic_id, :owner_user_id)
        end

        def find_active_repository(attrs)
          scope = Repository.active.includes(:user)
          if attrs[:repository_id].present?
            scope.find_by(id: attrs[:repository_id])
          else
            slug = attrs[:repository].presence || attrs[:repo].presence
            return if slug.blank?

            owner, name = slug.to_s.split("/", 2)
            return if owner.blank? || name.blank?

            scope.find_by(owner: owner, name: name)
          end
        end

        def find_epic(repository, epic_id)
          return if epic_id.blank?

          repository.epics.find_by(id: epic_id)
        end

        def find_owner_user(owner_user_id)
          return if owner_user_id.blank?

          User.find_by(id: owner_user_id)
        end

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
            validity:       job.validity,
            credential_mode: job.credential_mode,
            triaging_reason: job.triaging_reason,
            epic_id:        job.epic_id,
            owner_user_id:  job.owner_user_id,
            owner_user:     owner_user_json(job.owner_user),
            agent_provider: job.agent_provider,
            repository:     job.repository.slug,
            issue_number:   job.issue_number,
            issue_title:    job.issue_title,
            pr_number:      job.pr_number,
            branch_name:    job.branch_name,
            pr_mergeable:   job.pr_mergeable,
            pr_mergeable_checked_at: job.pr_mergeable_checked_at,
            github_mergeable: job.github_mergeable,
            github_mergeable_state: job.github_mergeable_state,
            mergeability_head_sha: job.mergeability_head_sha,
            mergeability_base_sha: job.mergeability_base_sha,
            mergeability_base_ref: job.mergeability_base_ref,
            mergeability_checked_at: job.mergeability_checked_at,
            local_mergeable: job.local_mergeable,
            local_mergeable_state: job.local_mergeable_state,
            local_mergeability_head_sha: job.local_mergeability_head_sha,
            local_mergeability_base_sha: job.local_mergeability_base_sha,
            local_mergeability_checked_at: job.local_mergeability_checked_at,
            last_seen_comment_at: job.last_seen_comment_at,
            last_feedback_addressed_at: job.last_feedback_addressed_at,
            last_ci_handled_sha: job.last_ci_handled_sha,
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
            validity: job.validity,
            credential_mode: job.credential_mode,
            invalidation_reason: job.invalidation_reason,
            invalidation_evidence: job.invalidation_evidence,
            triaging_reason: job.triaging_reason,
            epic_id: job.epic_id,
            owner_user_id: job.owner_user_id,
            owner_user: owner_user_json(job.owner_user),
            agent_provider: job.agent_provider,
            stack_base: job.stack_base,
            parent_job_id: job.parent_job_id,
            effective_base_branch: job.effective_base_branch,
            closure_reason: job.closure_reason,
            failure_count: job.failure_count,
            repository: {
              id: job.repository.id,
              slug: job.repository.slug,
              default_branch: job.repository.default_branch,
              auto_merge_enabled: job.repository.auto_merge_enabled,
              approval_propagates_to_github: job.repository.approval_propagates_to_github,
              credential_mode: job.repository.credential_mode,
              app_credential_active: job.repository.app_credential_active?,
              installation: installation_payload(job.repository.installation)
            },
            user_email: job.user.email_address,
            user: user_github_payload(job.user),
            issue_number: job.issue_number,
            issue_title: job.issue_title,
            branch_name: job.branch_name,
            pr_number: job.pr_number,
            external_pr_number: job.external_pr_number,
            pr_mergeable: job.pr_mergeable,
            pr_mergeable_checked_at: job.pr_mergeable_checked_at,
            github_mergeable: job.github_mergeable,
            github_mergeable_state: job.github_mergeable_state,
            mergeability_head_sha: job.mergeability_head_sha,
            mergeability_base_sha: job.mergeability_base_sha,
            mergeability_base_ref: job.mergeability_base_ref,
            mergeability_checked_at: job.mergeability_checked_at,
            local_mergeable: job.local_mergeable,
            local_mergeable_state: job.local_mergeable_state,
            local_mergeability_head_sha: job.local_mergeability_head_sha,
            local_mergeability_base_sha: job.local_mergeability_base_sha,
            local_mergeability_checked_at: job.local_mergeability_checked_at,
            scheduled_task_id: job.scheduled_task_id,
            started_at: job.started_at,
            finished_at: job.finished_at,
            approved_at: job.approved_at,
            approved_via: job.approved_via,
            approved_by_user_id: job.approved_by_user_id,
            approval_evidence: job.approval_evidence,
            last_seen_comment_at: job.last_seen_comment_at,
            last_feedback_addressed_at: job.last_feedback_addressed_at,
            last_ci_handled_sha: job.last_ci_handled_sha,
            landing_failure_reason: job.landing_failure_reason,
            created_at: job.created_at,
            updated_at: job.updated_at,
            workflows: job.workflows.order(:created_at).map { |wf| ::Admin::JobStateSerializer.workflow(wf) }
          }
        rescue => e
          ::Admin::JobStateSerializer.per_record_error(job, e)
        end

        def github_pr_snapshot(job)
          pr_number = job.pr_number || job.external_pr_number
          return unless pr_number

          pr = GithubClient.for(repository: job.repository, user: job.user)
                           .pull_request(job.repository.slug, pr_number, bypass_cache: true)

          {
            number: pr.number,
            state: pr.state,
            merged: pr.merged,
            mergeable: pr.mergeable,
            mergeable_state: (pr.mergeable_state if pr.respond_to?(:mergeable_state)),
            draft: (pr.draft if pr.respond_to?(:draft)),
            head_ref: pr.head&.ref,
            head_sha: pr.head&.sha,
            head_repo: pr.head&.repo&.full_name,
            base_ref: pr.base&.ref,
            base_sha: pr.base&.sha,
            base_repo: pr.base&.repo&.full_name
          }
        rescue => e
          {
            error: "#{e.class}: #{e.message.to_s.split(/ \/\/ /, 2).first}"
          }
        end

        def user_github_payload(user)
          {
            id: user.id,
            email_address: user.email_address,
            github_api_blocked: user.gh_api_blocked?,
            github_api_blocked_at: user.gh_api_blocked_at,
            github_api_blocked_reason: user.gh_api_blocked_reason,
            github_rate_limit: github_rate_limit_payload(user)
          }
        end

        def owner_user_json(owner_user)
          return nil unless owner_user

          {
            id: owner_user.id,
            email_address: owner_user.email_address
          }
        end

        def github_rate_limit_payload(user)
          return unless user.gh_rate_limit_remaining

          {
            remaining: user.gh_rate_limit_remaining,
            limit: user.gh_rate_limit_limit,
            resource: user.gh_rate_limit_resource,
            reset_at: user.gh_rate_limit_reset_at,
            observed_at: user.gh_rate_limit_observed_at,
            percent: user.gh_rate_limit_limit.to_i.positive? ?
              (user.gh_rate_limit_remaining.to_f / user.gh_rate_limit_limit) : nil
          }
        end

        def installation_payload(installation)
          return unless installation

          {
            id: installation.id,
            github_installation_id: installation.github_installation_id,
            account_login: installation.account_login,
            account_type: installation.account_type,
            active: installation.active?,
            removed_at: installation.removed_at
          }
        end
      end
    end
  end
end
