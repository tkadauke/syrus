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

    result = []

    epic_proposals.each do |epic_proposal|
      epic = epic_proposal.epic
      next unless epic

      children_proposals = epic_children[epic_proposal.id]
      child_items        = children_proposals.filter_map { |p| build_job_item(p) }
      done_count         = children_proposals.count { |p| p.job && job_done?(p.job) }

      result << {
        kind:     "epic",
        epic_id:  epic.id,
        slug:     epic.slug,
        title:    epic.title,
        state:    epic.state,
        progress: { done: done_count, total: child_items.size },
        children: child_items
      }
    end

    standalone_jobs.each do |proposal|
      item = build_job_item(proposal)
      result << item if item
    end

    result
  end

  private

  def build_job_item(proposal)
    job = proposal.job
    return nil unless job

    {
      kind:          "job",
      job_id:        job.id,
      slug:          job.slug,
      title:         job.title,
      state:         job.state,
      workflow_step: current_workflow_step(job),
      pr_number:     job.pr_number,
      pr_url:        job_pr_url(job),
      blocker:       blocker_for(job)
    }
  end

  def current_workflow_step(job)
    workflow = job.workflows.where(state: "running").order(:created_at).last
    return nil unless workflow

    step = workflow.current_step
    step ? step.kind : workflow.trigger_kind
  end

  def job_pr_url(job)
    return nil if job.pr_number.blank?

    "https://github.com/#{job.repository.slug}/pull/#{job.pr_number}"
  end

  def blocker_for(job)
    if job.implemented? && job.approved_at.nil?
      { reason: "awaiting_review", description: "Waiting for PR review and approval" }
    elsif (job.approved? || job.landing?) && latest_auto_merge_failed?(job)
      { reason: "landing_failed", description: "Auto-merge failed; check the landing queue" }
    elsif job.queued? && dependency_failed?(job)
      { reason: "dependency_failed", description: "A dependency job failed to complete successfully" }
    end
  end

  def latest_auto_merge_failed?(job)
    job.workflows.where(trigger_kind: "auto_merge").order(:created_at).last&.failed?
  end

  def dependency_failed?(job)
    job.dependencies.includes(:depends_on_job).any? do |dep|
      dep.depends_on_job&.closed? &&
        !Job::SUCCESSFUL_CLOSURE_REASONS.include?(dep.depends_on_job.closure_reason)
    end
  end

  def job_done?(job)
    job.closed? && Job::SUCCESSFUL_CLOSURE_REASONS.include?(job.closure_reason)
  end
end
