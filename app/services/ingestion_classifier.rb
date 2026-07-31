require "json"
require "set"
require "tmpdir"

class IngestionClassifier
  DEFAULT_TIMEOUT_SECONDS = 30
  DEFAULT_MAX_TURNS = 3
  DUPLICATE_CANDIDATE_LIMIT = 5

  Result = Data.define(:epic_id, :invalid_kind, :reason, :evidence_urls, :error) do
    def success? = error.nil?
    def invalid? = invalid_kind.present?
  end

  def self.call(...) = new(...).call

  def initialize(job:, agent: nil, github_client: nil,
                 timeout: DEFAULT_TIMEOUT_SECONDS,
                 max_turns: DEFAULT_MAX_TURNS,
                 now: Time.current)
    @job = job
    @repository = job.repository
    @user = job.user
    @agent = agent || OneShotAgent.new(user: @user, provider: job.workflow_agent_provider)
    @github_client = github_client
    @timeout = timeout
    @max_turns = max_turns
    @now = now
  end

  def call
    return failure("job is not awaiting classifier triage") unless classifier_pending_job?

    result = invoke_classifier
    return mark_uncertain(result.error) unless result.success?

    apply(result)
    result
  rescue StandardError => e
    mark_uncertain("#{e.class}: #{e.message}")
  end

  private

  attr_reader :job, :repository, :user, :agent, :timeout, :max_turns, :now

  def classifier_pending_job?
    job.triaging? && job.triaging_reason_classifier_pending?
  end

  def invoke_classifier
    prompt = Prompts::IngestionClassifier.new(
      job: job,
      epics: epic_index,
      merged_pull_requests: merged_pull_request_index,
      duplicate_candidates: duplicate_candidate_index
    ).to_s

    result = agent.run_once(
      prompt: prompt,
      log_sink: ->(*, **) { },
      timeout: timeout,
      max_turns: max_turns
    )

    return failure("timed out after #{timeout}s") if result.timed_out
    return failure("agent reported #{result.outcome || 'error'}") if result.is_error
    return failure("agent exited #{result.exit_status}") unless result.success?
    return failure("empty response") if result.final_text.blank?

    parse(result.final_text)
  end

  def parse(raw)
    text = raw.to_s.strip
    text = text.sub(/\A```(?:json)?\s*\n/, "").sub(/\n```\s*\z/, "").strip
    parsed = JSON.parse(text)

    invalid = parsed["invalid"].is_a?(Hash) ? parsed["invalid"] : {}
    kind = invalid["kind"].to_s.presence
    return failure("invalid kind #{kind.inspect}") if kind && !Job::VALIDITIES.include?(kind)
    return failure("invalid kind must not be valid") if kind == "valid"

    epic_id = parsed["epic_id"].presence
    epic_id = Integer(epic_id) if epic_id

    Result.new(
      epic_id: epic_id,
      invalid_kind: kind,
      reason: invalid["reason"].to_s.strip.presence,
      evidence_urls: Array(invalid["evidence_urls"]).map(&:to_s).map(&:strip).select(&:present?),
      error: nil
    )
  rescue JSON::ParserError => e
    failure("invalid JSON: #{e.message[0..120]}")
  rescue ArgumentError
    failure("epic_id must be an integer or null")
  end

  def apply(result)
    job.transaction do
      assign_epic(result.epic_id) if result.epic_id

      if result.invalid?
        invalidate!(result)
      else
        job.advance_after_triage! if job.may_advance_after_triage?
      end
    end
  end

  def assign_epic(epic_id)
    epic = user.epics.find_by(id: epic_id, repository_id: repository.id)
    raise ActiveRecord::RecordInvalid.new(job), "classifier returned unknown Epic ##{epic_id}" unless epic

    job.update!(epic: epic)
  end

  def invalidate!(result)
    job.update!(
      validity: result.invalid_kind,
      invalidation_reason: result.reason,
      invalidation_evidence: result.evidence_urls,
      closure_reason: result.invalid_kind,
      finished_at: Time.current
    )
    job.close! if job.may_close?
  end

  def mark_uncertain(reason)
    Rails.logger.warn("[IngestionClassifier] #{job.slug} uncertain: #{reason}")
    job.mark_classifier_uncertain! if job.may_mark_classifier_uncertain?
    failure(reason)
  end

  def epic_index
    user.epics
        .where(state: %w[ backlog ready in_progress ])
        .where("created_at >= ?", now - 90.days)
        .includes(:repository)
        .order(created_at: :desc)
        .limit(25)
        .map do |epic|
      {
        id: epic.id,
        title: epic.title.to_s,
        description: epic.description.to_s,
        repository: epic.repository.slug,
        state: epic.state
      }
    end
  end

  def merged_pull_request_index
    client = github_client
    return [] unless client

    Array(client.list_pull_requests_for_triage(repository.slug, state: "merged", limit: 25))
      .select { |pull| pull_merged_at(pull).blank? || pull_merged_at(pull) >= now - 30.days }
      .map do |pull|
      {
        number: pull.number,
        title: pull.title.to_s,
        body: pull.body.to_s,
        url: pull.html_url.to_s,
        merged_at: pull_merged_at(pull)&.iso8601
      }
    end
  rescue StandardError => e
    Rails.logger.warn("[IngestionClassifier] merged PR index failed for #{repository.slug}: #{e.class}: #{e.message}")
    []
  end

  def duplicate_candidate_index
    candidates = repository.jobs
                           .open_threads
                           .where.not(id: job.id)
                           .where(validity: "valid")
                           .where.not(issue_number: nil)
                           .order(created_at: :desc)
                           .limit(100)

    candidates.map { |candidate| [ text_similarity(job_text(job), job_text(candidate)), candidate ] }
              .select { |score, _candidate| score.positive? }
              .sort_by { |score, candidate| [ -score, -candidate.created_at.to_i ] }
              .first(DUPLICATE_CANDIDATE_LIMIT)
              .map { |_score, candidate| duplicate_candidate_payload(candidate) }
  end

  def duplicate_candidate_payload(candidate)
    {
      job_id: candidate.id,
      issue_number: candidate.issue_number,
      title: candidate.issue_title.to_s,
      body: candidate.issue_body.to_s.truncate(1_500),
      url: issue_url(candidate)
    }
  end

  def job_text(record)
    "#{record.issue_title} #{record.issue_body}".downcase.scan(/[a-z0-9]+/)
  end

  def text_similarity(left_tokens, right_tokens)
    left = left_tokens.to_set
    right = right_tokens.to_set
    return 0.0 if left.empty? || right.empty?

    (left & right).size.to_f / (left | right).size
  end

  def issue_url(record)
    "https://github.com/#{record.repository.owner}/#{record.repository.name}/issues/#{record.issue_number}"
  end

  def github_client
    @github_client ||= GithubClient.for(repository: repository, user: user)
  rescue StandardError => e
    Rails.logger.warn("[IngestionClassifier] GitHub client unavailable for #{repository.slug}: #{e.class}: #{e.message}")
    nil
  end

  def pull_merged_at(pull)
    value = pull.respond_to?(:merged_at) ? pull.merged_at : nil
    value.respond_to?(:to_time) ? value.to_time : value
  end

  def failure(reason)
    Result.new(epic_id: nil, invalid_kind: nil, reason: nil, evidence_urls: [], error: reason)
  end

  class OneShotAgent
    def initialize(user:, provider:)
      @user = user
      @provider = provider
    end

    def run_once(prompt:, log_sink:, timeout:, max_turns:)
      AgentProviders.run_one_shot(
        provider: @provider,
        user: @user,
        runner: RunJob.agent_runner,
        scope: "ingestion-classifier",
        prompt: prompt,
        log_sink: log_sink,
        timeout: timeout,
        max_turns: max_turns
      )
    end
  end
end
