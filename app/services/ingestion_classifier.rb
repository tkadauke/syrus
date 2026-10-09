require "json"
require "set"
require "tmpdir"

class IngestionClassifier
  DEFAULT_TIMEOUT_SECONDS = 30
  DEFAULT_MAX_TURNS = 3
  DUPLICATE_CANDIDATE_LIMIT = 5
  DUPLICATE_TEXT_BYTES = 20_000
  DUPLICATE_TOKEN_LIMIT = 400

  Result = Data.define(:epic_id, :invalid_kind, :reason, :evidence_urls, :planned_execution, :raw_output, :spawned_process_id, :error) do
    def success? = error.nil?
    def invalid? = invalid_kind.present?
  end

  def self.call(...) = new(...).call

  def initialize(job:, runner: nil, github_client: nil,
                 timeout: DEFAULT_TIMEOUT_SECONDS,
                 max_turns: DEFAULT_MAX_TURNS,
                 now: Time.current)
    @job = job
    @repository = job.repository
    @user = job.user
    # `runner` rather than a bespoke agent object: the judgment itself is the
    # primitive now, and this is the same seam every other one-shot caller has.
    @runner = runner
    @github_client = github_client
    @timeout = timeout
    @max_turns = max_turns
    @now = now
  end

  def call
    return failure("job is not awaiting classifier triage") unless classifier_pending_job?

    attempt = start_attempt!
    record_attempt!
    result = with_attempt_process_attribution(attempt) { invoke_classifier }
    attempt.update_columns(spawned_process_id: result.spawned_process_id) if result.spawned_process_id && attempt.spawned_process_id != result.spawned_process_id
    unless result.success?
      finish_attempt!(attempt, outcome: "uncertain", error: result.error, raw_output: result.raw_output)
      return mark_uncertain(result.error)
    end

    apply(result)
    finish_attempt!(attempt, outcome: "classified", decision: decision_payload(result), raw_output: result.raw_output)
    result
  rescue StandardError => e
    finish_attempt!(attempt, outcome: "errored", error: "#{e.class}: #{e.message}") if attempt
    mark_uncertain("#{e.class}: #{e.message}")
  end

  private

  attr_reader :job, :repository, :user, :agent, :timeout, :max_turns, :now

  def classifier_pending_job?
    job.triaging? && job.triaging_reason_classifier_pending?
  end

  # Every attempt counts, successful or not: the cap exists to stop a Job
  # cycling through the classifier forever, and a run that ended in a decision
  # consumed the same budget as one that ended in an error.
  def record_attempt!
    job.increment!(:classifier_attempts)
  end

  def start_attempt!
    job.classification_attempts.create!(
      started_at: Time.current,
      agent_provider: job.workflow_agent_provider
    )
  end

  def with_attempt_process_attribution(attempt)
    previous = Thread.current[:syrus_current_job_classification_attempt]
    previous_job = Thread.current[:syrus_current_job]
    Thread.current[:syrus_current_job_classification_attempt] = attempt
    Thread.current[:syrus_current_job] = job
    yield
  ensure
    Thread.current[:syrus_current_job_classification_attempt] = previous
    Thread.current[:syrus_current_job] = previous_job
  end

  def invoke_classifier
    prompt = Prompts::IngestionClassifier.new(
      job: job,
      epics: epic_index,
      merged_pull_requests: merged_pull_request_index,
      duplicate_candidates: duplicate_candidate_index,
      repository_capabilities: repository_capability_index
    ).to_s

    judgment = Judgment.call(
      scope: "ingestion-classifier",
      prompt: prompt,
      user: @user,
      provider: job.workflow_agent_provider,
      runner: @runner,
      timeout: timeout,
      max_turns: max_turns
    )
    return failure(judgment.error, raw_output: judgment.raw_text, spawned_process_id: judgment.spawned_process_id) if judgment.failed?

    parse(judgment.value, raw_output: judgment.raw_text, spawned_process_id: judgment.spawned_process_id)
  end

  def parse(parsed, raw_output: nil, spawned_process_id: nil)
    return failure("invalid JSON: expected an object", raw_output: raw_output, spawned_process_id: spawned_process_id) unless parsed.is_a?(Hash)

    invalid = parsed["invalid"].is_a?(Hash) ? parsed["invalid"] : {}
    kind = invalid["kind"].to_s.presence
    return failure("invalid kind #{kind.inspect}", raw_output: raw_output, spawned_process_id: spawned_process_id) if kind && !Job::VALIDITIES.include?(kind)
    return failure("invalid kind must not be valid", raw_output: raw_output, spawned_process_id: spawned_process_id) if kind == "valid"

    epic_id = parsed["epic_id"].presence
    epic_id = Integer(epic_id) if epic_id

    Result.new(
      epic_id: epic_id,
      invalid_kind: kind,
      reason: invalid["reason"].to_s.strip.presence,
      evidence_urls: Array(invalid["evidence_urls"]).map(&:to_s).map(&:strip).select(&:present?),
      planned_execution: planned_execution_attributes(parsed["planned_execution"]),
      raw_output: raw_output,
      spawned_process_id: spawned_process_id,
      error: nil
    )
  rescue ArgumentError
    failure("epic_id must be an integer or null", raw_output: raw_output, spawned_process_id: spawned_process_id)
  end

  def apply(result)
    job.transaction do
      assign_epic(result.epic_id) if result.epic_id

      if result.invalid?
        invalidate!(result)
      else
        apply_planned_execution!(result)
        job.advance_after_triage! if job.may_advance_after_triage?
      end
    end
  end

  def apply_planned_execution!(result)
    requirement =
      if result.planned_execution.present?
        PlannedExecutionRequirement.new(**result.planned_execution.merge(source: "classifier").symbolize_keys)
      else
        PlannedExecutionPlanner.for_job(job)
      end
    requirement.assign_to(job)
    job.save! if job.planned_execution_changed?
  rescue StandardError => e
    Rails.logger.warn("[IngestionClassifier] planned execution classification failed for #{job.slug}: #{e.class}: #{e.message}")
    PlannedExecutionPlanner.for_job(job).assign_to(job)
    job.save! if job.planned_execution_changed?
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

  # Uncertainty used to be recorded only in the process log, which meant that
  # by the time anyone noticed the Job was stuck sat for three
  # weeks -- there was no way to tell a transient provider error from an issue
  # that genuinely needs a person. The reason is now on the Job, and the Job is
  # put in front of someone rather than left to be found.
  def mark_uncertain(reason)
    Rails.logger.warn("[IngestionClassifier] #{job.slug} uncertain: #{reason}")
    if job.may_mark_classifier_uncertain?
      job.mark_classifier_uncertain!
      job.update_columns(triaging_uncertainty_reason: reason.to_s.truncate(1_000))
    end
    failure(reason)
  end

  def finish_attempt!(attempt, outcome:, decision: nil, error: nil, raw_output: nil)
    return if attempt.finished_at.present?

    attempt.finish!(
      outcome: outcome,
      decision: decision,
      error: error,
      raw_output: raw_output
    )
  end

  def decision_payload(result)
    {
      classification: result.invalid? ? "invalid" : "valid",
      epic_id: result.epic_id,
      invalid_kind: result.invalid_kind,
      reason: result.reason,
      evidence_urls: result.evidence_urls,
      planned_execution: result.planned_execution
    }
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
    job_tokens = job_text(job)
    candidates = repository.jobs
                           .open_threads
                           .where.not(id: job.id)
                           .where(validity: "valid")
                           .where.not(issue_number: nil)
                           .order(created_at: :desc)
                           .limit(100)

    candidates.map { |candidate| [ text_similarity(job_tokens, job_text(candidate)), candidate ] }
              .select { |score, _candidate| score.positive? }
              .sort_by { |score, candidate| [ -score, -candidate.created_at.to_i ] }
              .first(DUPLICATE_CANDIDATE_LIMIT)
              .map { |_score, candidate| duplicate_candidate_payload(candidate) }
  end

  def repository_capability_index
    loaded = RepoDefaultBranchSyrusYml.for_job(job)
    return { status: loaded.outcome.to_s, warning: "repository capability metadata unavailable", facts: [] } unless loaded.loaded?

    facts = []
    project = loaded.config.project
    if project&.capabilities&.to_h.present?
      facts << {
        kind: "project",
        label: project.label.presence || project.id.presence || "Repository",
        target_label: TargetGraph.root_label.to_s,
        capabilities: project.capabilities.to_h
      }
    end
    Array(loaded.config.targets).each do |target|
      next unless target.capabilities&.to_h.present?

      facts << {
        kind: "target",
        label: target.name,
        target_label: TargetGraph::Label.root(target.name).to_s,
        capabilities: target.capabilities.to_h
      }
    end
    Array(loaded.config.grade&.steps).each do |step|
      next unless step.capabilities&.to_h.present?

      facts << {
        kind: "grader",
        label: step.display_name.presence || step.name,
        target_label: TargetGraph::Label.root("grade/#{step.name}").to_s,
        capabilities: step.capabilities.to_h
      }
    end

    {
      status: "loaded",
      warning: (facts.empty? ? "repository has no capability metadata; infer conservatively from the issue text" : nil),
      facts: facts
    }
  rescue StandardError => e
    Rails.logger.warn("[IngestionClassifier] capability index failed for #{repository.slug}: #{e.class}: #{e.message}")
    { status: "unavailable", warning: "repository capability metadata unavailable", facts: [] }
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
    text = "#{record.issue_title} #{record.issue_body}".downcase.safe_byteslice(0, DUPLICATE_TEXT_BYTES)
    text.to_s.split(/[^a-z0-9]+/).reject(&:blank?).first(DUPLICATE_TOKEN_LIMIT)
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

  def failure(reason, raw_output: nil, spawned_process_id: nil)
    Result.new(
      epic_id: nil,
      invalid_kind: nil,
      reason: nil,
      evidence_urls: [],
      planned_execution: nil,
      raw_output: raw_output,
      spawned_process_id: spawned_process_id,
      error: reason
    )
  end

  def planned_execution_attributes(value)
    return nil unless value.is_a?(Hash)

    capabilities = value["capabilities"]
    return nil unless capabilities.is_a?(Hash) && capabilities.present?

    {
      project_label: value["project_label"],
      target_label: value["target_label"],
      capabilities: capabilities
    }
  end
end
