class ChatJobStatusQuery
  JOB_PROPOSAL_KINDS = %w[job syrus_issue].freeze

  def self.call(chat_session)
    new(chat_session).call
  end

  def initialize(chat_session)
    @chat_session = chat_session
  end

  def call
    proposals = @chat_session.proposals
      .confirmed
      .includes(job: :repository, epic: [])
      .to_a

    epic_proposals = proposals.select(&:epic?)
    job_proposals  = proposals.select { |p| JOB_PROPOSAL_KINDS.include?(p.kind) }

    epic_proposal_ids = epic_proposals.map(&:id).to_set
    epic_children     = Hash.new { |h, k| h[k] = [] }
    standalone_jobs   = []

    job_proposals.each do |proposal|
      if proposal.parent_proposal_id && epic_proposal_ids.include?(proposal.parent_proposal_id)
        epic_children[proposal.parent_proposal_id] << proposal
      else
        standalone_jobs << proposal
      end
    end

    proposal_job_ids = job_proposals.filter_map { |p| p.job&.id }.to_set
    direct_jobs = Job.where(linked_chat_id: @chat_session.id, kind: "direct")
       .includes(:repository)
       .where.not(id: proposal_job_ids)
       .to_a

    preload_runtime_state!(job_proposals.filter_map(&:job) + direct_jobs)

    result = []

    epic_proposals.each do |epic_proposal|
      epic = epic_proposal.epic
      next unless epic

      children_proposals = epic_children[epic_proposal.id]
      child_items        = children_proposals.filter_map { |p| build_job_item(p) }
                             .sort_by { |c| c[:updated_at] }.reverse
      done_count         = children_proposals.count { |p| p.job && job_done?(p.job) }
      latest_updated_at  = child_items.map { |c| c[:updated_at] }.max || epic.updated_at.iso8601

      result << {
        kind:              "epic",
        epic_id:           epic.id,
        slug:              epic.slug,
        title:             epic.title,
        state:             epic.state,
        progress:          { done: done_count, total: child_items.size },
        children:          child_items,
        latest_updated_at: latest_updated_at
      }
    end

    standalone_jobs.each do |proposal|
      item = build_job_item(proposal)
      result << item if item
    end

    direct_jobs.each { |job| result << build_job_hash(job) }

    result.sort_by { |item| item[:latest_updated_at] || item[:updated_at] || "" }.reverse
  end

  private

  def preload_runtime_state!(jobs)
    jobs = jobs.compact.uniq(&:id)
    job_ids = jobs.map(&:id)

    @active_workflows_by_job_id = latest_workflows_by_job_id(job_ids, state: %w[ queued running ])

    workflow_ids = @active_workflows_by_job_id.values.map(&:id)
    @current_steps_by_workflow_id = current_steps_by_workflow_id(workflow_ids)

    landing_job_ids = jobs.select { |job| job.approved? || job.landing? }.map(&:id)
    @latest_auto_merge_workflows_by_job_id = latest_workflows_by_job_id(landing_job_ids, trigger_kind: "auto_merge")

    queued_job_ids = jobs.select(&:queued?).map(&:id)
    @failed_dependency_by_job_id = failed_dependency_by_job_id(queued_job_ids)
  end

  def build_job_item(proposal)
    job = proposal.job
    return nil unless job

    build_job_hash(job)
  end

  def build_job_hash(job)
    {
      kind:          "job",
      job_id:        job.id,
      slug:          job.slug,
      title:         job.title,
      state:         job.state,
      workflow_step: current_workflow_step(job),
      active_workflow: active_workflow_hash(job),
      pr_number:     job.pr_number,
      pr_url:        job_pr_url(job),
      blocker:       blocker_for(job),
      updated_at:    job.updated_at.iso8601
    }
  end

  def current_workflow_step(job)
    workflow = active_workflow_for(job)
    return nil unless workflow

    step = @current_steps_by_workflow_id&.fetch(workflow.id, nil)
    step ? step.kind : workflow.trigger_kind
  end

  def active_workflow_hash(job)
    workflow = active_workflow_for(job)
    return nil unless workflow

    {
      id: workflow.id,
      slug: workflow.slug,
      state: workflow.state,
      trigger_kind: workflow.trigger_kind,
      step: current_workflow_step(job)
    }
  end

  def active_workflow_for(job)
    @active_workflows_by_job_id&.fetch(job.id, nil)
  end

  def job_pr_url(job)
    return nil if job.pr_number.blank?

    "https://github.com/#{job.repository.slug}/pull/#{job.pr_number}"
  end

  def blocker_for(job)
    if job.implemented? && job.approved_at.nil? && active_workflow_for(job).nil?
      { reason: "awaiting_review", description: "Waiting for PR review and approval" }
    elsif (job.approved? || job.landing?) && latest_auto_merge_failed?(job)
      { reason: "landing_failed", description: "Auto-merge failed; check the landing queue" }
    elsif job.queued? && dependency_failed?(job)
      { reason: "dependency_failed", description: "A dependency job failed to complete successfully" }
    end
  end

  def latest_auto_merge_failed?(job)
    @latest_auto_merge_workflows_by_job_id&.fetch(job.id, nil)&.failed?
  end

  def dependency_failed?(job)
    @failed_dependency_by_job_id&.fetch(job.id, false)
  end

  def job_done?(job)
    job.closed? && Job::SUCCESSFUL_CLOSURE_REASONS.include?(job.closure_reason)
  end

  def latest_workflows_by_job_id(job_ids, state: nil, trigger_kind: nil)
    return {} if job_ids.empty?

    scope = Workflow.where(job_id: job_ids)
    scope = scope.where(state: state) if state
    scope = scope.where(trigger_kind: trigger_kind) if trigger_kind

    scope.order(:job_id, :created_at, :id).to_a.each_with_object({}) do |workflow, result|
      result[workflow.job_id] = workflow
    end
  end

  def current_steps_by_workflow_id(workflow_ids)
    return {} if workflow_ids.empty?

    active_steps = Step
      .where(workflow_id: workflow_ids, state: %w[ queued running ])
      .order(:workflow_id, :position, :id)
      .to_a
      .each_with_object({}) { |step, result| result[step.workflow_id] ||= step }

    missing_workflow_ids = workflow_ids - active_steps.keys
    return active_steps if missing_workflow_ids.empty?

    Step
      .where(workflow_id: missing_workflow_ids)
      .order(:workflow_id, :position, :id)
      .to_a
      .each_with_object(active_steps) { |step, result| result[step.workflow_id] = step }
  end

  def failed_dependency_by_job_id(job_ids)
    return {} if job_ids.empty?

    JobDependency
      .where(job_id: job_ids)
      .includes(:depends_on_job)
      .each_with_object(Hash.new(false)) do |dependency, result|
        depends_on_job = dependency.depends_on_job
        next unless depends_on_job&.closed?
        next if Job::SUCCESSFUL_CLOSURE_REASONS.include?(depends_on_job.closure_reason)

        result[dependency.job_id] = true
      end
  end
end
