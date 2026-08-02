require "set"

class ChatScopedEventRecipients
  def initialize(repository: nil, job: nil, epic: nil, proposal: nil, workflow: nil, run: nil, pr_number: nil, details: nil)
    @details = details
    @run = run
    @workflow = workflow || run&.workflow
    @job = job || @workflow&.job || run&.job
    @repository = repository || @job&.repository
    @pr_number = pr_number
    @job ||= job_for_pull_request
    @epic = epic || @job&.epic
    @proposal = proposal
  end

  attr_reader :repository, :job, :epic, :proposal

  def chat_sessions
    ids = Set.new
    ids << proposal.chat_session_id if proposal&.confirmed?
    ids.merge(chat_ids_for_job(job)) if job
    ids.merge(chat_ids_for_epic(epic)) if epic

    ChatSession.where(id: ids.to_a, system_kind: nil)
  end

  private

  def chat_ids_for_job(job)
    proposal_scope.where(job_id: job.id).pluck(:chat_session_id)
  end

  def chat_ids_for_epic(epic)
    proposal_scope.where(epic_id: epic.id).pluck(:chat_session_id)
  end

  def proposal_scope
    ChatProposal.confirmed
  end

  def job_for_pull_request
    number = pull_request_number
    return unless repository && number

    Job
      .where(repository: repository)
      .where("pr_number = :number OR external_pr_number = :number", number: number)
      .order(:created_at, :id)
      .last
  end

  def pull_request_number
    explicit = Integer(@pr_number, exception: false)
    return explicit if explicit&.positive?

    detail_value = details_hash["pr_number"] || details_hash[:pr_number]
    detail_number = Integer(detail_value, exception: false)
    return detail_number if detail_number&.positive?

    pr_url = details_hash["pr_url"] || details_hash[:pr_url]
    match = pr_url.to_s.match(%r{/pull/(\d+)(?:\z|[?#])})
    return unless match

    Integer(match[1], exception: false)
  end

  def details_hash
    @details.is_a?(Hash) ? @details : {}
  end
end
