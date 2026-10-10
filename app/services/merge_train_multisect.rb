class MergeTrainMultisect
  ARTIFACT_KEY = "merge_train_multisect".freeze
  DEFAULT_SECTION_WIDTH = 4
  MIN_SECTION_WIDTH = 2
  MAX_SECTION_WIDTH = 16

  Evaluation = Data.define(:reproduced, :reason, :details) do
    def self.reproduced(details: {}) = new(true, "reproduced", details)
    def self.clean(reason: "focused_selector_did_not_reproduce", details: {}) = new(false, reason, details)
    def reproduced? = reproduced
  end

  Result = Data.define(:attributed, :member, :reason, :rounds, :payload) do
    def attributed? = attributed
  end

  def self.call(...) = new(...).call

  def initialize(workflow:, train:, section_width: DEFAULT_SECTION_WIDTH, evaluator:, determinism_gate: nil, log: nil)
    @workflow = workflow
    @train = train
    @section_width = normalize_section_width(section_width)
    @evaluator = evaluator
    @determinism_gate = determinism_gate || DeterminismGate.new(workflow: workflow, log: log)
    @log = log || ->(_message) {}
    @rounds = []
  end

  def call
    members = train.members.includes(:job).order(:position).to_a
    return abort!("not_enough_members", members: members_payload(members)) if members.size < 2

    selector = focused_selector
    return abort!("empty_focused_selector", members: members_payload(members), failing_set: []) if selector.empty?

    unless determinism_gate.reproducible?
      return abort!("flaky_oracle", members: members_payload(members), failing_set: selector,
        determinism: determinism_gate.payload)
    end

    oracle = evaluate(section: members, round: 0, role: "oracle", selector: selector)
    unless oracle.reproduced?
      return abort!("oracle_did_not_reproduce", members: members_payload(members), failing_set: selector,
        oracle: evaluation_payload(oracle))
    end

    candidates = members
    while candidates.size > 1
      sections = partition(candidates)
      graded_sections = sections[0...-1]
      omitted_section = sections.last
      reproducing = []
      evaluations = graded_sections.each_with_index.map do |section, index|
        evaluation = evaluate(section: section, round: rounds.size + 1, role: "section", selector: selector)
        reproducing << { index: index, section: section, evaluation: evaluation } if evaluation.reproduced?
        section_payload(section, index: index, omitted: false, evaluation: evaluation)
      end
      evaluations << section_payload(omitted_section, index: sections.size - 1, omitted: true, evaluation: nil)
      rounds << {
        "round" => rounds.size + 1,
        "candidate_member_ids" => candidates.map(&:job_id),
        "sections" => evaluations
      }

      if reproducing.size > 1
        return abort!("multiple_sections_reproduced", members: members_payload(members), failing_set: selector,
          reproducing_section_indexes: reproducing.map { |entry| entry[:index] })
      end

      candidates = if reproducing.one?
        reproducing.first.fetch(:section)
      else
        omitted_section
      end

      if candidates.empty? || candidates.size == members.size
        return abort!("no_subset_reproduced", members: members_payload(members), failing_set: selector)
      end
    end

    attributed_member = candidates.first
    payload = base_payload(
      reason: "isolated_member",
      members: members_payload(members),
      failing_set: selector
    ).merge(
      "attributed_member" => member_payload(attributed_member)
    )
    record!(payload)
    Result.new(true, attributed_member, "isolated_member", rounds, payload)
  end

  private

  attr_reader :workflow, :train, :section_width, :evaluator, :determinism_gate, :rounds

  def normalize_section_width(value)
    Integer(value).clamp(MIN_SECTION_WIDTH, MAX_SECTION_WIDTH)
  rescue ArgumentError, TypeError
    DEFAULT_SECTION_WIDTH
  end

  def focused_selector
    rounds = Array(workflow.artifact(GraderLoopProgress::ARTIFACT_KEY))
    stop = workflow.artifact(GraderLoopProgress::STOP_ARTIFACT_KEY)
    failing_set = Array(stop && stop["failing_set"]).presence ||
      Array(rounds.max_by { |round| round.to_h["iteration"].to_i }.to_h["failing_set"])
    failing_set.map(&:to_s).map(&:strip).reject(&:empty?).uniq.sort
  end

  def partition(members)
    width = [ section_width, members.size ].min
    size = (members.size.to_f / width).ceil
    members.each_slice(size).to_a
  end

  def evaluate(section:, round:, role:, selector:)
    evaluator.call(
      workflow: workflow,
      train: train,
      members: section,
      failing_set: selector,
      round: round,
      role: role
    )
  end

  def abort!(reason, **extra)
    payload = base_payload(reason: reason, **extra)
    record!(payload)
    Result.new(false, nil, reason, rounds, payload)
  end

  def base_payload(reason:, members: nil, failing_set: nil, **extra)
    {
      "status" => reason == "isolated_member" ? "attributed" : "aborted",
      "reason" => reason,
      "section_width" => section_width,
      "rounds" => rounds,
      "members" => members || members_payload(train.members.includes(:job).order(:position)),
      "failing_set" => Array(failing_set),
      "recorded_at" => Time.current.iso8601
    }.merge(extra.deep_stringify_keys)
  end

  def record!(payload)
    workflow.set_artifact!(ARTIFACT_KEY, payload)
    if payload["status"] == "attributed"
      member = payload.fetch("attributed_member")
      @log.call("[merge_train_multisect] attributed focused train failure to #{member.fetch('job_slug')}")
    else
      @log.call("[merge_train_multisect] aborted: #{payload['reason']}")
    end
  end

  def section_payload(section, index:, omitted:, evaluation:)
    {
      "index" => index,
      "omitted" => omitted,
      "members" => members_payload(section),
      "reproduced" => evaluation&.reproduced?,
      "reason" => evaluation&.reason,
      "details" => evaluation&.details.to_h
    }.compact
  end

  def members_payload(members)
    members.map { |member| member_payload(member) }
  end

  def member_payload(member)
    {
      "merge_train_member_id" => member.id,
      "job_id" => member.job_id,
      "job_slug" => member.job.slug,
      "position" => member.position
    }
  end

  def evaluation_payload(evaluation)
    {
      "reproduced" => evaluation.reproduced?,
      "reason" => evaluation.reason,
      "details" => evaluation.details.to_h
    }
  end

  class DeterminismGate
    def initialize(workflow:, log: nil)
      @workflow = workflow
      @log = log || ->(_message) {}
      @payload = {}
    end

    attr_reader :payload

    def reproducible?
      flaky = Adjudicators::KnownFlakyFailure.adjudicate(
        problem: Problem[:grader_failure],
        workflow: workflow
      )
      if flaky.dismiss?
        @payload = { "gate" => "known_flaky_failure", "verdict" => flaky.to_h }
        return false
      end

      base_results = base_retry_results
      inherited = base_results.any? { |result| result.ran && result.inherited }
      @payload = { "gate" => "base_revision_retry", "base_retry_results" => base_results.map(&:to_h) } if base_results.any?
      !inherited
    rescue StandardError => e
      log.call("[merge_train_multisect] determinism gate raised #{e.class}: #{e.message}")
      @payload = { "gate" => "error", "error" => "#{e.class}: #{e.message}" }
      false
    end

    private

    attr_reader :workflow, :log

    def base_retry_results
      base_sha = workflow.artifact("merge_train_base_sha").to_s.presence
      return [] unless base_sha

      TestEvidenceLookup.failed_grader_steps(workflow).filter_map do |grader_step|
        failed_cases = TestEvidenceLookup.failed_test_cases_for(grader_step.latest_run, grader_step.details.to_h["name"])
        BaseRevisionRetry.call(
          workflow: workflow,
          grader_step: grader_step,
          base_sha: base_sha,
          failed_cases: failed_cases,
          log: log
        )
      end
    end
  end
end
