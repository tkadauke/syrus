module Jobs
  class Filter
    PARAM_KEYS = %w[ state repository_id pr age attention tag_ids ].freeze

    attr_reader :params, :user

    # `user:` is required for any filter that needs operator context —
    # currently the `pinned` attention filter, which joins job_pins
    # for the requesting user. Callers that don't pass a user can
    # still use the user-agnostic filters (state, repo, etc.).
    def initialize(params, user: nil)
      sliced = params.to_h.slice(*PARAM_KEYS)
      # tag_ids is multi-valued; preserve it as an array of strings and
      # drop empty entries so callers can pass raw form values.
      if sliced["tag_ids"].present?
        ids = Array(sliced["tag_ids"]).flatten.compact_blank.map(&:to_s)
        sliced["tag_ids"] = ids.presence
      end
      @params = sliced.compact_blank
      @user = user
    end

    def pinned?
      params["attention"] == "pinned"
    end

    def apply(relation)
      relation = apply_attention(relation)
      relation = apply_state(relation)
      relation = apply_repository(relation)
      relation = apply_pr(relation)
      relation = apply_age(relation)
      apply_tags(relation)
    end

    def active?
      params.any?
    end

    def to_h
      params
    end

    private

    def apply_state(relation)
      case params["state"]
      when "open", "closed"
        relation.where(state: params["state"])
      when "failed", "succeeded"
        relation.open_threads.where(id: latest_workflow_job_ids(params["state"]))
      else
        relation
      end
    end

    def apply_repository(relation)
      return relation if params["repository_id"].blank?

      relation.where(repository_id: params["repository_id"])
    end

    def apply_pr(relation)
      case params["pr"]
      when "has_pr" then relation.with_pr
      when "no_pr" then relation.without_pr
      else relation
      end
    end

    def apply_age(relation)
      cutoff = { "1d" => 1.day.ago, "7d" => 7.days.ago, "30d" => 30.days.ago }[params["age"]]
      return relation unless cutoff

      relation.where(created_at: cutoff..)
    end

    def apply_tags(relation)
      ids = Array(params["tag_ids"]).compact_blank
      return relation if ids.empty?

      relation.joins(:job_tags).where(job_tags: { tag_id: ids }).distinct
    end

    def apply_attention(relation)
      case params["attention"]
      when "pinned"
        return relation unless user

        relation.joins(:job_pins).where(job_pins: { user_id: user.id })
      when "in_progress"
        relation.open_threads.where(id: Workflow.active.select(:job_id))
      when "inbox"
        # Closed jobs never need attention — even if their latest run
        # failed or they have unread feedback, the operator chose to
        # close them. Filter to open_threads.
        relation.open_threads
                .where(id: awaiting_operator_job_ids)
                .or(relation.open_threads.where(id: unread_feedback_job_ids))
                .or(relation.open_threads.where(id: latest_failed_run_job_ids))
      when "just_failed"
        relation.where(id: latest_failed_run_job_ids)
      when "in_review"
        relation.open_threads.with_pr.where(id: latest_workflow_job_ids("succeeded"))
      when "stale"
        relation.open_threads.where(updated_at: ..7.days.ago)
      when "blocked"
        relation.where(id: blocked_dependency_job_ids).or(relation.where(pr_mergeable: false))
      when "merged_this_week"
        relation.closed_threads
                .where(closure_reason: %w[ pr_merged external_pr_merged ])
                .where(finished_at: 7.days.ago..)
      else
        relation
      end
    end

    def latest_workflow_job_ids(state)
      Workflow.where(state: state)
              .where(<<~SQL.squish)
                workflows.id = (
                  SELECT latest_workflows.id
                  FROM workflows latest_workflows
                  WHERE latest_workflows.job_id = workflows.job_id
                  ORDER BY latest_workflows.created_at DESC, latest_workflows.id DESC
                  LIMIT 1
                )
              SQL
              .select(:job_id)
    end

    def latest_failed_run_job_ids
      Run.where(state: "failed")
         .where(<<~SQL.squish)
           runs.id = (
             SELECT latest_runs.id
             FROM runs latest_runs
             WHERE latest_runs.job_id = runs.job_id
             ORDER BY latest_runs.created_at DESC, latest_runs.id DESC
             LIMIT 1
           )
         SQL
         .select(:job_id)
    end

    def awaiting_operator_job_ids
      Run.where(state: "awaiting_operator").select(:job_id)
    end

    def unread_feedback_job_ids
      Job.where.not(last_seen_comment_at: nil)
         .where("last_feedback_addressed_at IS NULL OR last_seen_comment_at > last_feedback_addressed_at")
         .select(:id)
    end

    def blocked_dependency_job_ids
      successful_jobs = Job.closed_threads.where(closure_reason: Job::SUCCESSFUL_CLOSURE_REASONS)

      JobDependency.pending
                   .or(JobDependency.resolved.where.not(depends_on_job_id: successful_jobs.select(:id)))
                   .select(:job_id)
    end
  end
end
