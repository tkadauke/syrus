class ChatProposalFiler
  Result = Struct.new(:proposals, :jobs, :epics, :github_issue_numbers, :warnings, keyword_init: true) do
    def filed_count
      proposals.size
    end
  end

  def initialize(user:, repository:)
    @user = user
    @repository = repository
  end

  def file!(selected_proposals)
    ordered = self.class.ordered_closure(selected_proposals)
    ensure_repository_scope!(ordered)

    jobs = []
    epics = []
    github_issue_numbers = {}
    warnings = self.class.warnings_for(ordered)

    ApplicationRecord.transaction do
      job_by_proposal_id = existing_jobs_for(ordered)

      ordered.each do |proposal|
        next unless proposal.proposed?

        materialized = create_record_for(proposal)
        proposal_attrs = {
          state: "confirmed",
          filed_at: Time.current,
          confirmed_at: Time.current
        }

        case materialized
        when Job
          proposal_attrs[:job] = materialized
          jobs << materialized
          job_by_proposal_id[proposal.id] = materialized
        when Epic
          proposal_attrs[:epic] = materialized
          epics << materialized
        when nil
          github_issue_numbers[proposal.id] = proposal.github_issue_number
        end

        proposal.update!(proposal_attrs)
        wire_dependencies_for(proposal, materialized, job_by_proposal_id)
        start_direct_workflow(materialized, proposal) if materialized.is_a?(Job)
      end
    end

    Result.new(proposals: ordered, jobs: jobs, epics: epics, github_issue_numbers: github_issue_numbers, warnings: warnings)
  end

  def self.ordered_closure(selected_proposals)
    closure = ChatProposal.transitive_upstream_closure(selected_proposals)
    ChatProposal.topological_sort(closure.to_a)
  end

  def self.warnings_for(proposals)
    kinds = proposals.map(&:kind).uniq
    warnings = []
    if kinds.include?("github_issue") && kinds.include?("syrus_issue")
      warnings << "This cascade mixes Syrus jobs and GitHub issues. Dependencies are wired only between Syrus job proposals."
    elsif kinds.include?("github_issue") && kinds.include?("epic")
      warnings << "This cascade mixes Epics and GitHub issues. GitHub issue dependencies are not materialized immediately."
    end
    if proposals.any? { |proposal| proposal.github_issue? && (proposal.dependencies.any? || proposal.dependents.any?) }
      warnings << "GitHub issue proposals are filed to GitHub and picked up later by polling, so cross-proposal dependencies involving them are not created now."
    end
    warnings
  end

  private

  attr_reader :user, :repository

  def ensure_repository_scope!(proposals)
    foreign = proposals.find { |proposal| proposal.effective_repository&.id != repository.id }
    raise ActiveRecord::RecordNotFound, "proposal #{foreign.id} is outside this repository" if foreign
  end

  def existing_jobs_for(proposals)
    proposals.select { |proposal| proposal.filed? && proposal.job_id.present? }
      .index_by(&:id)
      .transform_values(&:job)
  end

  def create_record_for(proposal)
    case proposal.kind
    when "syrus_issue", "job"
      create_direct_job(proposal)
    when "github_issue"
      file_github_issue(proposal)
      nil
    when "epic"
      create_epic(proposal)
    else
      raise ArgumentError, "unsupported proposal kind: #{proposal.kind}"
    end
  end

  def create_direct_job(proposal)
    target_repository = proposal.effective_repository || repository

    user.jobs.create!(
      repository: target_repository,
      epic: proposal.target_epic,
      kind: "direct",
      issue_number: nil,
      issue_title: proposal.title,
      issue_body: proposal.body,
      agent_provider: target_repository.effective_agent_provider
    ).tap(&:advance_after_triage!)
  end

  def create_epic(proposal)
    user.epics.create!(
      repository: proposal.effective_repository || repository,
      title: proposal.title,
      description: proposal.body
    )
  end

  def file_github_issue(proposal)
    issue = GithubClient.for(repository: repository, user: user).create_issue(
      repository.slug,
      title: proposal.title,
      body: proposal.body,
      labels: github_labels_for(proposal)
    )
    proposal.github_issue_number = issue.number
  end

  def github_labels_for(proposal)
    labels = parse_labels(proposal.labels)
    (labels + [ repository.trigger_label ]).map(&:to_s).map(&:strip).reject(&:blank?).uniq
  end

  def parse_labels(value)
    return [] if value.blank?

    parsed = JSON.parse(value)
    Array(parsed)
  rescue JSON::ParserError
    value.to_s.split(",")
  end

  def wire_dependencies_for(proposal, materialized, job_by_proposal_id)
    wire_job_dependencies_for(proposal, materialized, job_by_proposal_id) if materialized.is_a?(Job)
    wire_epic_dependencies_for(proposal, materialized) if materialized.is_a?(Epic)
  end

  def wire_job_dependencies_for(proposal, job, job_by_proposal_id)
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

  def wire_epic_dependencies_for(proposal, epic)
    proposal.dependencies.includes(:epic).each do |dependency|
      depends_on_epic = dependency.epic
      next unless depends_on_epic

      EpicDependency.create!(
        epic: epic,
        depends_on_epic: depends_on_epic,
        derived: false
      )
    end
  end

  def start_direct_workflow(job, proposal)
    workflow = Workflows::Initial.instantiate(job: job, agent_provider: job.agent_provider)
    StepDispatcher.start_workflow(workflow, prompt: Prompts::DirectJob.new(prompt: proposal.body).to_s)
  end
end
