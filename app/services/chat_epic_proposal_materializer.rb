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

    job_proposals = proposed_children_for(epic_proposal)
    jobs = []
    epic = nil

    ApplicationRecord.transaction do
      epic = create_epic_for(epic_proposal)
      epic_proposal.update!(
        epic: epic,
        state: "confirmed",
        filed_at: Time.current,
        confirmed_at: Time.current
      )

      job_by_proposal_id = {}
      job_proposals.each do |proposal|
        job = create_job_for(proposal, epic)
        proposal.update!(
          job: job,
          state: "confirmed",
          filed_at: Time.current,
          confirmed_at: Time.current
        )
        job_by_proposal_id[proposal.id] = job
        jobs << job
      end

      wire_sibling_dependencies(job_proposals, job_by_proposal_id)
    end

    Result.new(epic_proposal: epic_proposal, epic: epic, job_proposals: job_proposals, jobs: jobs)
  end

  private

  attr_reader :user

  def proposed_children_for(epic_proposal)
    proposals = epic_proposal.child_proposals.includes(:dependencies).where(state: "proposed").to_a
    ChatProposal.topological_sort(proposals)
  end

  def create_epic_for(proposal)
    repository = proposal.repository || proposal.chat_session.repository
    user.epics.create!(
      repository: repository,
      title: proposal.title,
      description: proposal.body
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
    ).tap(&:advance_after_triage!)
  end

  def wire_sibling_dependencies(job_proposals, job_by_proposal_id)
    job_proposals.each do |proposal|
      job = job_by_proposal_id.fetch(proposal.id)
      proposal.dependencies.each do |dependency|
        depends_on_job = job_by_proposal_id[dependency.id]
        next unless depends_on_job

        JobDependency.create!(
          job: job,
          depends_on_job: depends_on_job,
          source: "manual",
          created_by_user: user
        )
      end
    end
  end
end
