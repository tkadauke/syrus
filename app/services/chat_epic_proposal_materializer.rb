class ChatEpicProposalMaterializer
  Result = Struct.new(:epic_proposal, :epic, :job_proposals, :jobs, keyword_init: true) do
    def filed_count
      1 + job_proposals.size
    end
  end

  def initialize(user:)
    @user = user
  end

  def file!(epic_proposal)
    raise ArgumentError, "proposal must be an epic bundle" unless epic_proposal.epic?
    raise ArgumentError, "proposal is no longer proposed" unless epic_proposal.proposed?

    @chat_session = epic_proposal.chat_session
    job_proposals = proposed_children_for(epic_proposal)
    ensure_active_repositories!([ epic_proposal ] + job_proposals)
    jobs = []
    epic = nil

    ApplicationRecord.transaction do
      epic = create_epic_for(epic_proposal)
      chat_session.chat_attachments.find_or_create_by!(attachable: epic)
      epic_proposal.update!(
        epic: epic,
        state: "confirmed",
        filed_at: Time.current,
        confirmed_at: Time.current
      )

      job_by_proposal_id = {}
      job_proposals.each do |proposal|
        job = create_job_for(proposal, epic)
        chat_session.chat_attachments.find_or_create_by!(attachable: job)
        proposal.update!(
          job: job,
          state: "confirmed",
          filed_at: Time.current,
          confirmed_at: Time.current
        )
        job_by_proposal_id[proposal.id] = job
        jobs << job
        resolve_pending_proposal_dependencies_for(proposal, job)
      end

      wire_sibling_dependencies(job_proposals, job_by_proposal_id)
      wire_epic_dependencies(epic_proposal, epic)
      wire_job_epic_dependencies(job_proposals, job_by_proposal_id)
      ChatEpicProposalDependencyWirer.new(user: user).resolve_confirmed_proposal!(epic_proposal)
      jobs.each { |job| job.advance_after_triage! if job.may_advance_after_triage? }
    end

    Result.new(epic_proposal: epic_proposal, epic: epic, job_proposals: job_proposals, jobs: jobs)
  end

  private

  attr_reader :user, :chat_session

  def ensure_active_repositories!(proposals)
    archived = proposals.map(&:effective_repository).compact.find(&:archived?)
    raise ArgumentError, "repository #{archived.slug} is archived" if archived
  end

  def proposed_children_for(epic_proposal)
    proposals = epic_proposal.child_proposals.includes(:dependencies).where(state: "proposed").to_a
    ChatProposal.topological_sort(proposals)
  end

  def create_epic_for(proposal)
    repository = proposal.repository || proposal.chat_session.repository
    # Chat-authored Epics are fully-specified by Claude in one shot;
    # land them in :ready so the operator can promote to :in_progress
    # without first walking them through the backlog→ready transition
    # (which is meant for partially-specified epics).
    user.epics.create!(
      repository: repository,
      title: proposal.title,
      description: proposal.body,
      state: "ready"
    )
  end

  def create_job_for(proposal, epic)
    repository = proposal.repository || epic.repository
    user.jobs.create!(
      repository: repository,
      epic: epic,
      kind: "direct",
      issue_number: nil,
      issue_title: proposal.title,
      issue_body: proposal.body,
      agent_provider: repository.effective_agent_provider
    )
  end

  def wire_sibling_dependencies(job_proposals, job_by_proposal_id)
    job_proposals.each do |proposal|
      job = job_by_proposal_id.fetch(proposal.id)
      proposal.dependencies.each do |dependency|
        depends_on_job = job_by_proposal_id[dependency.id] || dependency.job
        unless depends_on_job
          create_pending_proposal_dependency!(job, dependency)
          next
        end

        JobDependency.find_or_create_by!(
          job: job,
          depends_on_job: depends_on_job
        ) do |job_dependency|
          job_dependency.source = "manual"
          job_dependency.created_by_user = user
        end
      end
    end
  end

  def create_pending_proposal_dependency!(job, dependency)
    return unless dependency.syrus_issue? || dependency.job?

    JobDependency.find_or_create_by!(
      job: job,
      unresolved_chat_proposal: dependency
    ) do |job_dependency|
      job_dependency.source = "manual"
      job_dependency.created_by_user = user
    end
  end

  def resolve_pending_proposal_dependencies_for(proposal, job)
    JobDependency.pending.where(unresolved_chat_proposal: proposal).find_each do |dependency|
      next unless dependency.job.user_id == user.id

      dependency.resolve!(depends_on_job: job)
      Rails.logger.info(
        "[JobDependency] resolved pending proposal dep on job ##{dependency.job_id}: " \
        "#{proposal.slug} -> job ##{job.id}"
      )
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.warn(
        "[JobDependency] failed to resolve pending proposal dep on job ##{dependency.job_id}: #{e.message}"
      )
    end
  end

  def create_job_epic_dependency!(job, epic)
    JobDependency.create!(
      job: job,
      depends_on_epic: epic,
      source: "manual",
      created_by_user: user
    )
  end

  def wire_epic_dependencies(proposal, epic)
    Array(proposal.depends_on_job_ids).each do |job_id|
      dep_job = user.jobs.find_by(id: job_id)
      next unless dep_job

      EpicDependency.create!(
        epic: epic,
        depends_on_job: dep_job,
        derived: false
      )
    end

    ChatEpicProposalDependencyWirer.new(user: user).wire_for!(proposal)
  end

  def wire_job_epic_dependencies(job_proposals, job_by_proposal_id)
    job_proposals.each do |proposal|
      job = job_by_proposal_id.fetch(proposal.id)
      Array(proposal.depends_on_epic_ids).each do |epic_id|
        epic = user.epics.find_by(id: epic_id)
        next unless epic

        create_job_epic_dependency!(job, epic)
      end
    end
  end

end
