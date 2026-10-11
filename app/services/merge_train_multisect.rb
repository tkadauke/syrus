require "open3"
require "shellwords"
require "timeout"

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

  def self.focused_selector_for(workflow)
    rounds = Array(workflow.artifact(GraderLoopProgress::ARTIFACT_KEY))
    stop = workflow.artifact(GraderLoopProgress::STOP_ARTIFACT_KEY)
    failing_set = Array(stop && stop["failing_set"]).presence ||
      Array(rounds.max_by { |round| round.to_h["iteration"].to_i }.to_h["failing_set"])
    failing_set.map(&:to_s).map(&:strip).reject(&:empty?).uniq.sort
  end

  def self.members_payload(members)
    members.map { |member| member_payload(member) }
  end

  def self.member_payload(member)
    {
      "merge_train_member_id" => member.id,
      "job_id" => member.job_id,
      "job_slug" => member.job.slug,
      "position" => member.position
    }
  end

  def self.partition(members, section_width)
    width = [ normalize_section_width(section_width), members.size ].min
    size = (members.size.to_f / width).ceil
    members.each_slice(size).to_a
  end

  def self.normalize_section_width(value)
    Integer(value).clamp(MIN_SECTION_WIDTH, MAX_SECTION_WIDTH)
  rescue ArgumentError, TypeError
    DEFAULT_SECTION_WIDTH
  end

  def initialize(workflow:, train:, section_width: DEFAULT_SECTION_WIDTH, evaluator:, determinism_gate: nil, log: nil)
    @workflow = workflow
    @train = train
    @section_width = self.class.normalize_section_width(section_width)
    @evaluator = evaluator
    @determinism_gate = determinism_gate || DeterminismGate.new(workflow: workflow, log: log)
    @log = log || ->(_message) { }
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
      omitted_evaluation = omitted_evaluation_for(omitted_section, reproducing: reproducing, selector: selector)
      reproducing << { index: sections.size - 1, section: omitted_section, evaluation: omitted_evaluation } if omitted_evaluation&.reproduced?
      evaluations << section_payload(omitted_section, index: sections.size - 1, omitted: true, evaluation: omitted_evaluation)
      rounds << {
        "round" => rounds.size + 1,
        "candidate_member_ids" => candidates.map(&:job_id),
        "sections" => evaluations
      }

      if reproducing.size > 1
        return abort!("multiple_sections_reproduced", members: members_payload(members), failing_set: selector,
          reproducing_section_indexes: reproducing.map { |entry| entry[:index] })
      end
      unless reproducing.one?
        return abort!("no_subset_reproduced", members: members_payload(members), failing_set: selector)
      end

      candidates = reproducing.first.fetch(:section)

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

  def focused_selector
    self.class.focused_selector_for(workflow)
  end

  def partition(members)
    self.class.partition(members, section_width)
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

  def omitted_evaluation_for(section, reproducing:, selector:)
    return nil unless reproducing.one?

    evaluate(section: section, round: rounds.size + 1, role: "omitted_confirmation", selector: selector)
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
    self.class.members_payload(members)
  end

  def member_payload(member)
    self.class.member_payload(member)
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
      @log = log || ->(_message) { }
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

  class FocusedEvaluator
    TIMEOUT_SECONDS = 10.minutes

    def initialize(workflow:, train:, log: nil, git: nil, workspace_path: nil)
      @workflow = workflow
      @train = train
      @log = log || ->(_message) { }
      @git = git || GitRunner.new(workflow: workflow, env: { "GIT_TERMINAL_PROMPT" => "0", "GIT_EDITOR" => "true" })
      @workspace_path = Pathname(workspace_path || WorkflowWorkspace.path_for(workflow))
    end

    def call(members:, failing_set:, round:, role:, **)
      return Evaluation.clean(reason: "focused_selector_empty") if failing_set.empty?
      return Evaluation.clean(reason: "workspace_unavailable") unless workspace_path.directory?

      grader_contexts = failed_grader_contexts(failing_set)
      return Evaluation.clean(reason: "focused_selector_empty") if grader_contexts.empty?

      with_subset_checkout(members, round: round, role: role) do
        grader_contexts.each do |context|
          command = focused_command(context)
          next if command.blank?

          evaluation = run_focused_command(context, command, failing_set)
          return evaluation if evaluation.reproduced?
        end
      end

      Evaluation.clean(reason: "focused_selector_did_not_reproduce")
    rescue StandardError => e
      log.call("[merge_train_multisect] focused subset grade failed for #{role}: #{e.class}: #{e.message}")
      Evaluation.clean(reason: "focused_subset_error", details: { error: "#{e.class}: #{e.message}" })
    end

    private

    attr_reader :workflow, :train, :log, :git, :workspace_path

    GraderContext = Data.define(:step, :name, :failed_cases)

    def failed_grader_contexts(failing_set)
      TestEvidenceLookup.failed_grader_steps(workflow).filter_map do |grader_step|
        name = grader_step.details.to_h["name"].to_s.presence
        next unless name

        failed_cases = TestEvidenceLookup.failed_test_cases_for(grader_step.latest_run, name)
        failed_cases = cases_from_failing_set(failing_set) if failed_cases.empty?
        next if failed_cases.empty?

        GraderContext.new(grader_step, name, failed_cases)
      end
    end

    def cases_from_failing_set(failing_set)
      failing_set.filter_map do |identity|
        suite_name, name = identity.to_s.split("\0", 2)
        next if suite_name.blank? || name.blank?

        {
          "suite_name" => suite_name,
          "name" => name,
          "file_path" => suite_name,
          "identity" => identity
        }
      end
    end

    def with_subset_checkout(members, round:, role:)
      original_ref = git.run("rev-parse", "--abbrev-ref", "HEAD", chdir: workspace_path.to_s).strip
      original_sha = git.run("rev-parse", "HEAD", chdir: workspace_path.to_s).strip
      subset_branch = "__syrus_multisect_#{workflow.id}_#{round}_#{role}"

      abort_rebase
      git.run("checkout", "-B", subset_branch, base_sha, chdir: workspace_path.to_s)
      members.each { |member| integrate_member!(member) }
      yield
    ensure
      restore_checkout(original_ref, original_sha, subset_branch)
    end

    def integrate_member!(member)
      branch = member.job.branch_name.to_s
      raise "member #{member.job.slug} has no branch" if branch.blank?

      fetch_branch(branch)
      temp_branch = "__syrus_multisect_member_#{member.id}"
      previous_tip = git.run("rev-parse", "HEAD", chdir: workspace_path.to_s).strip
      git.run("checkout", "-B", temp_branch, "FETCH_HEAD", chdir: workspace_path.to_s)
      git.run("rebase", previous_tip, chdir: workspace_path.to_s)
      git.run("checkout", "-", chdir: workspace_path.to_s)
      git.run("merge", "--ff-only", temp_branch, chdir: workspace_path.to_s)
      git.run("branch", "-D", temp_branch, chdir: workspace_path.to_s)
    rescue GitRunner::GitError => e
      abort_rebase
      raise "could not integrate #{branch}: #{e.message}"
    end

    def fetch_branch(branch)
      GithubAuthenticatedGit.run(repository: train.repository, user: workflow.job.user, git: git, operation_type: "git_merge_train_multisect_fetch", log: log) do |url|
        git.run("fetch", url, "refs/heads/#{branch}", chdir: workspace_path.to_s)
      end
    end

    def base_sha
      sha = workflow.artifact("merge_train_base_sha").to_s.presence
      return sha if sha

      git.run("rev-parse", "origin/#{train.base_branch}", chdir: workspace_path.to_s).strip
    end

    def focused_command(context)
      config = base_retry_config(context.step)
      return nil unless config
      return interpolate_explicit_command(config.fetch("command"), context.failed_cases) if config.fetch("strategy") == "command"
      return files_as_args_command(context.step, context.failed_cases) if config.fetch("strategy") == "files_as_args"

      Syrus::PluginRegistry.providers_for(:focused_test_command).each do |provider|
        command = provider.command_for(
          grader_name: context.name,
          grader_command: context.step.details.to_h["command"],
          failed_cases: context.failed_cases,
          base_retry: config
        )
        return command.to_s.strip if command.to_s.strip.present?
      rescue StandardError => e
        log.call("[merge_train_multisect] focused_test_command #{provider} declined with #{e.class}: #{e.message}")
      end
      nil
    end

    def base_retry_config(grader_step)
      raw = grader_step.details.to_h["base_retry"]
      return nil if raw.blank?
      return { "strategy" => "command", "command" => raw } if raw.is_a?(String)

      config = raw.to_h.stringify_keys
      strategy = config["strategy"].to_s
      return nil if strategy.blank?

      config.merge("strategy" => strategy)
    end

    def interpolate_explicit_command(command, failed_cases)
      files = failed_cases.filter_map { |test_case| test_case["file_path"].presence }.uniq.sort
      command
        .gsub("{files}", Shellwords.join(files))
        .gsub("{failed_count}", failed_cases.size.to_s)
    end

    def files_as_args_command(grader_step, failed_cases)
      files = failed_cases.filter_map { |test_case| test_case["file_path"].presence }.uniq.sort
      return nil if files.empty?

      "#{grader_step.details.to_h['command']} #{Shellwords.join(files)}"
    end

    def run_focused_command(context, command, failing_set)
      output = +""
      status = nil
      Timeout.timeout(TIMEOUT_SECONDS) do
        Open3.popen2e(env, "bash", "-c", command, chdir: workspace_path.to_s) do |stdin, stream, wait_thread|
          stdin.close
          stream.each { |chunk| output << chunk }
          status = wait_thread.value
        end
      end
      parsed = parse_result(context, output)
      return Evaluation.clean(reason: "focused_output_not_parseable") unless parsed

      failed = parsed.cases.select { |test_case| %w[failed error].include?(test_case.status) }
      identities = failed.map { |test_case| [ test_case.suite_name, test_case.name ].join("\0") }.uniq.sort
      reproduced = (identities & failing_set).any?
      details = {
        grader_name: context.name,
        command: CommandRedactor.redact(command),
        exit_status: status&.exitstatus,
        failed_identities: identities
      }
      reproduced ? Evaluation.reproduced(details: details) : Evaluation.clean(details: details)
    rescue Timeout::Error
      Evaluation.clean(reason: "focused_timeout", details: { grader_name: context.name })
    end

    def parse_result(context, output)
      junit_path = context.step.details.to_h["junit_output"].to_s.strip.presence
      if junit_path
        path = workspace_path.join(junit_path)
        return JunitXmlParser.parse(path.read) if path.file?
      end
      JunitXmlParser.parse(output)
    rescue JunitXmlParser::ParseError
      nil
    end

    def env
      { "RAILS_ENV" => "test", "GIT_TERMINAL_PROMPT" => "0" }
    end

    def restore_checkout(original_ref, original_sha, subset_branch)
      abort_rebase
      return unless original_sha

      target = original_ref.present? && original_ref != "HEAD" ? original_ref : original_sha
      git.run("checkout", target, chdir: workspace_path.to_s)
      git.run("reset", "--hard", original_sha, chdir: workspace_path.to_s)
      git.run("branch", "-D", subset_branch, chdir: workspace_path.to_s) if subset_branch
    rescue StandardError => e
      log.call("[merge_train_multisect] could not restore workspace after subset grade: #{e.class}: #{e.message}")
    end

    def abort_rebase
      git.run("rebase", "--abort", chdir: workspace_path.to_s)
    rescue GitRunner::GitError
      nil
    end
  end
end
