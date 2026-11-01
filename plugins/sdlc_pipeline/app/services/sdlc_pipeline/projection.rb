module SdlcPipeline
  class Projection
    HIGHLIGHT_LIMIT = 5
    PAGE_DEFAULT = 25
    PAGE_MAX = 50
    RECENT_TAIL_LIMIT = 50
    RECENT_TAIL_AGE = 30.days
    AGING_AGE = 7.days

    def initialize(repository:, user:, filter: Filter.from_tree({ "and" => [] }, user: user), stage: nil, page: 1, limit: PAGE_DEFAULT, now: Time.current)
      @repository = repository
      @user = user
      @selected_stage = stage.presence
      @page = [ page.to_i, 1 ].max
      @limit = limit.to_i.clamp(1, PAGE_MAX)
      @now = now
      @filter = filter
    end

    def call
      deployment_plan = RepoDeploymentStagesReader.for_repository(repository)
      entries = Stage.entries(deployment_plan.stages)
      jobs = load_jobs.select { |job| Stage.for(job, entries) }
      job_ids = jobs.map(&:id)
      @pinned_job_ids = JobPin.where(user_id: user.id, job_id: job_ids).pluck(:job_id).to_set
      @latest_workflow_ids = Workflow.where(job_id: job_ids).group(:job_id).maximum(:id)
      grouped = jobs.group_by { |job| Stage.for(job, entries).key }
      final_deployment_key = deployment_plan.stages.last && "deployment:#{deployment_plan.stages.last.name}"
      incomplete_evidence_count = delivery_evidence_gap_count(jobs, entries, final_deployment_key)

      {
        repository_id: repository.id,
        filter: filter.to_h,
        generated_at: now.iso8601,
        bounds: {
          highlighted_items_per_stage: HIGHLIGHT_LIMIT,
          recent_completion_days: (RECENT_TAIL_AGE / 1.day).to_i,
          recent_completion_limit: RECENT_TAIL_LIMIT,
          page_limit_max: PAGE_MAX
        },
        evidence: {
          status: incomplete_evidence_count.positive? ? "partial" : "complete",
          incomplete_count: incomplete_evidence_count
        },
        stages: entries.map { |entry| stage_payload(entry, grouped.fetch(entry.key, []), release_tail: entry.key == final_deployment_key) },
        groups: group_payload(jobs, entries),
        drill_down: drill_down_payload(grouped)
      }.compact
    end

    private

    attr_reader :repository, :user, :filter, :selected_stage, :page, :limit, :now

    def load_jobs
      relation = filter.apply(Job.visible_to(user))
        .where(repository_id: repository.id)
        .includes(:epic, :deployment_stage_statuses)
        .order(updated_at: :desc, id: :desc)

      open_jobs = relation.where.not(state: Job::TERMINAL_STATES).to_a
      recent = relation.where(state: Job::TERMINAL_STATES)
        .where("jobs.finished_at >= ? OR jobs.updated_at >= ?", now - RECENT_TAIL_AGE, now - RECENT_TAIL_AGE)
        .limit(RECENT_TAIL_LIMIT)
        .to_a
      (open_jobs + recent).uniq(&:id)
    end

    def stage_payload(entry, jobs, release_tail: false)
      ordered = ordered_jobs(jobs)
      ages = jobs.map { |job| age_seconds(job, entry.key) }
      {
        key: entry.key,
        label: entry.label,
        kind: entry.kind,
        release_tail: release_tail,
        total: jobs.length,
        attention_count: jobs.count(&:needs_attention?),
        aging_count: ages.count { |age| age >= AGING_AGE },
        oldest_age_seconds: ages.max&.to_i,
        highlighted_items: ordered.first(HIGHLIGHT_LIMIT).map { |job| item_payload(job, entry.key) },
        drill_down_path: "/api/v1/app/repositories/#{repository.id}/sdlc_pipeline?q=#{CGI.escapeURIComponent(filter.to_query_param)}&stage=#{CGI.escapeURIComponent(entry.key)}"
      }
    end

    def group_payload(jobs, entries)
      jobs.group_by(&:epic).map do |epic, grouped_jobs|
        {
          key: epic ? "epic:#{epic.id}" : "ungrouped",
          label: epic&.title || "Ungrouped",
          epic: epic && { id: epic.id, slug: epic.slug, title: epic.title },
          total: grouped_jobs.length,
          stage_totals: grouped_jobs.group_by { |job| Stage.for(job, entries).key }.transform_values(&:length)
        }
      end.sort_by { |group| group[:key] == "ungrouped" ? [ 1, group[:label] ] : [ 0, group[:label].downcase ] }
    end

    def drill_down_payload(grouped)
      return unless selected_stage

      jobs = ordered_jobs(grouped.fetch(selected_stage, []))
      offset = (page - 1) * limit
      {
        stage: selected_stage,
        page: page,
        limit: limit,
        total: jobs.length,
        next_page: offset + limit < jobs.length ? page + 1 : nil,
        items: jobs.slice(offset, limit).to_a.map { |job| item_payload(job, selected_stage) }
      }
    end

    def ordered_jobs(jobs)
      jobs.sort_by do |job|
        [
          pinned?(job) ? 0 : 1,
          job.needs_attention? ? 0 : 1,
          -activity_at(job).to_f,
          -job.id
        ]
      end
    end

    def item_payload(job, stage_key)
      {
        id: job.id,
        slug: job.slug,
        title: job.issue_title,
        state: job.state,
        epic: job.epic && { id: job.epic.id, slug: job.epic.slug, title: job.epic.title },
        needs_attention: job.needs_attention?,
        attention_reason: job.needs_attention_reason,
        pinned: pinned?(job),
        paths: item_paths(job, stage_key),
        age_seconds: age_seconds(job, stage_key).to_i,
        evidence: evidence(job, stage_key)
      }
    end

    def evidence(job, stage_key)
      status = job.deployment_stage_statuses.find { |candidate| "deployment:#{candidate.stage_name}" == stage_key }
      return { type: "deployment_stage", stage_name: status.stage_name, reached_at: status.reached_at.iso8601, tag_sha: status.tag_sha }.compact if status
      if stage_key == "landed"
        return { type: "landed_commit", landed_sha: job.landed_sha, finished_at: job.finished_at&.iso8601 }.compact if job.landed_sha.present?
        return { type: "completed", closure_reason: job.closure_reason, finished_at: job.finished_at&.iso8601 }.compact
      end

      { type: "job_state", state: job.state, changed_at: activity_at(job).iso8601 }
    end

    def age_seconds(job, stage_key) = now - occupied_at(job, stage_key)

    def occupied_at(job, stage_key)
      if stage_key.start_with?("deployment:")
        status = job.deployment_stage_statuses.find { |candidate| "deployment:#{candidate.stage_name}" == stage_key }
        return status.reached_at if status
      end

      {
        "implementing" => -> { job.started_at },
        "landing" => -> { job.approved_at },
        "landed" => -> { job.finished_at }
      }.fetch(stage_key, -> { }).call || activity_at(job)
    end

    def activity_at(job) = job.needs_attention_since || job.updated_at || job.created_at

    def pinned?(job) = @pinned_job_ids.include?(job.id)

    def item_paths(job, stage_key)
      latest_workflow_id = @latest_workflow_ids[job.id]
      paths = {
        job: "/jobs/#{job.slug}",
        workflow: latest_workflow_id && "/jobs/#{job.slug}?tab=workflows#workflow-#{latest_workflow_id}"
      }.compact
      paths[:delivery] = paths[:job] if stage_key.start_with?("deployment:") || stage_key == "landed"
      paths[:release] = paths[:job] if stage_key.start_with?("deployment:")
      paths
    end

    def delivery_evidence_gap_count(jobs, entries, final_deployment_key)
      return 0 unless final_deployment_key

      jobs.count do |job|
        stage = Stage.for(job, entries)
        stage&.key == "landed" || (stage&.kind == "deployment" && stage.key != final_deployment_key)
      end
    end
  end
end
