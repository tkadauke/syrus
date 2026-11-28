# frozen_string_literal: true

require "digest"
require "json"

module FailureCorpus
  # Reads recently failed Runs and turns each into a sanitized replay case:
  # exactly the inputs RunFailureClassifier reads, as they stood when the
  # instance last classified the Run, next to the verdict it recorded.
  #
  # Like Redactor this is streamed into a production `rails runner` by
  # bin/export-failure-corpus, so it may use only models and columns that
  # every deployed release has, and it never writes: callers wrap it in
  # `ActiveRecord::Base.while_preventing_writes`.
  #
  # Sanitizing loses text -- truncation drops the middle of a long log chunk,
  # redaction rewrites tokens -- and a lost word can change a verdict. So each
  # case is checked before it is kept: the instance's own classifier must
  # reach the same verdict on the sanitized inputs as on the raw ones. A case
  # that loses its verdict is retried with longer limits, and dropped if no
  # limit preserves it. Every case in the corpus therefore replays to the
  # exporting release's verdict; whatever differs on replay is code drift.
  class Exporter
    FORMAT_VERSION = 1

    # The classifier reads the newest 25 log chunks (RunFailureClassifier::
    # RECENT_LOG_LIMIT) and only spawned processes finished in the last hour
    # (SpawnedProcess.recent_or_active). Repeated here rather than referenced
    # because the release this runs on may differ from the one replaying.
    LOG_LIMIT = 25
    PROCESS_WINDOW = 3600

    LIMITS = {
      chunk: 4_000,
      message: 4_000,
      backtrace_lines: 30,
      summary: 2_000,
      command: 400
    }.freeze
    # Successive multipliers of LIMITS tried until sanitizing keeps the verdict.
    SCALES = [ 1, 4, 16 ].freeze

    # Deduplicated cases kept per fingerprint, and the overall cap.
    PER_FINGERPRINT = 2
    DEFAULT_LIMIT = 400

    # Product and provider words appear in the messages the classifier reads
    # ("mcp__syrus-mcp-sidecar", "Syrus could push"); never anonymize them
    # even when an owner or user happens to share the name.
    PRESERVED_WORDS = %w[syrus claude codex muse gemini github example user admin bot root main].freeze

    # A verdict RunFailureClassifier itself persisted carries its full
    # classifier_inputs; one written directly by a repair (a workspace that
    # could not be recovered, a RunJob that kept crashing) does not.
    CLASSIFIER_INPUT_KEYS = %w[run_state step_kind].freeze

    attr_reader :stats

    def self.call(**kwargs)
      new(**kwargs).call
    end

    def initialize(days: 30, limit: DEFAULT_LIMIT, per_fingerprint: PER_FINGERPRINT, now: Time.now)
      @since = now - (days.to_i * 86_400)
      @limit = limit.to_i
      @per_fingerprint = per_fingerprint.to_i
      @stats = Hash.new(0)
    end

    def call
      Redactor.identifiers = instance_identifiers
      buckets = Hash.new { |hash, key| hash[key] = [] }
      seen_texts = Hash.new { |hash, key| hash[key] = {} }

      failed_runs.find_each(order: :desc) do |run|
        classification = run.run_failure_classification
        next unless classification

        @stats["runs"] += 1
        fingerprint = fingerprint(sanitized_case(run, classification, 1))
        next if buckets[fingerprint].size >= @per_fingerprint

        kase = faithful_case(run, classification)
        next if kase.nil?

        text_key = kase.delete("text_digest")
        next if seen_texts[fingerprint].key?(text_key)

        seen_texts[fingerprint][text_key] = true
        buckets[fingerprint] << kase
      end

      select_balanced(buckets)
    end

    # The sanitized case at the smallest scale whose verdict matches the raw
    # inputs' verdict under this release's classifier, or nil.
    def faithful_case(run, classification)
      raw_case = build_case(run, classification, scale: nil)
      if (drift = evidence_drift(run, raw_case, classifier_inputs(classification)))
        @stats["dropped_evidence_#{drift}"] += 1
        return nil
      end

      raw = verdict(run, raw_case)
      SCALES.each do |scale|
        kase = sanitized_case(run, classification, scale)
        next unless verdict(run, kase) == raw

        @stats["scale_#{scale}"] += 1
        kase["export_verdict"] = { "classification" => raw[0], "retryable" => raw[1] }
        return kase
      end
      @stats["dropped_lossy"] += 1
      nil
    rescue StandardError => e
      @stats["verdict_error #{e.class}"] += 1
      nil
    end

    def sanitized_case(run, classification, scale)
      build_case(run, classification, scale: scale)
    end

    # The case for one Run. `scale: nil` builds the raw, unredacted inputs used
    # only for the fidelity check; they are never emitted.
    def build_case(run, classification, scale:)
      @scale = scale
      classified_at = classification.classified_at || classification.updated_at
      diagnostic = run.run_diagnostic
      inputs = classifier_inputs(classification)
      snapshot = diagnostic&.repo_snapshot
      snapshot = {} unless snapshot.is_a?(Hash)

      logs = logs_for(run, classified_at)
      kase = {
        "format" => FORMAT_VERSION,
        "run" => {
          "trigger_kind" => run.trigger_kind,
          "agent_provider" => run.agent_provider,
          "agent_outcome" => run.agent_outcome,
          "agent_summary" => clip(run.agent_summary, :summary),
          "agent_pr_title" => clip(run.agent_pr_title, :summary),
          "agent_pr_body" => clip(run.agent_pr_body, :summary)
        },
        "step_kind" => run.step&.kind,
        "step_details" => step_details(run.step),
        "workflow" => {
          "trigger_kind" => run.workflow&.trigger_kind,
          "failure_reason" => clip(run.workflow&.failure_reason, :message)
        },
        "diagnostic" => diagnostic && {
          "error_class" => diagnostic.error_class,
          "error_message" => clip(diagnostic.error_message, :message),
          "error_backtrace" => backtrace(diagnostic.error_backtrace),
          "problem_code" => diagnostic.respond_to?(:problem_code) ? diagnostic.problem_code : nil,
          "problem_evidence" => scrub_value(diagnostic.respond_to?(:problem_evidence) ? diagnostic.problem_evidence : nil),
          "repo_snapshot" => {
            "run_outcome" => clip(snapshot["run_outcome"], :message),
            "workflow_failure_reason" => clip(snapshot["workflow_failure_reason"], :message)
          }.compact.presence
        }.compact,
        "logs" => logs,
        "spawned_processes" => processes_for(run, classified_at),
        "host_pressure_level" => resource_summary(run)&.host_pressure_level,
        "context" => {
          "deploy_rollover_near_failure" => inputs["deploy_rollover_near_failure"] == true,
          "macos_worker_update_near_failure" => inputs["macos_worker_update_near_failure"] == true
        },
        "recorded" => {
          "classification" => classification.classification,
          "retryable" => classification.retryable == true,
          "confidence" => classification.confidence&.to_f,
          "source" => CLASSIFIER_INPUT_KEYS.all? { |key| inputs.key?(key) } ? "classifier" : "external",
          "classified_on" => classified_at&.utc&.strftime("%Y-%m-%d")
        },
        "auto_retry_attempts" => attempts_for(run)
      }
      kase["text_digest"] = Digest::SHA256.hexdigest(normalize(logs.last(3).map { |log| log["chunk"] }.join("\n")))[0, 16]
      kase["id"] = "#{fingerprint(kase)}-#{kase['text_digest']}"
      kase
    end

    private

    # Which of the classifier's recorded inputs no longer match the evidence
    # the export can read, or nil. The recorded verdict is only a baseline
    # when the evidence behind it survives: spawned-process rows are pruned
    # after their retention window, and a repair can rewrite a Run's outcome
    # after it was classified. Replaying such a case would report a "change"
    # that is lost evidence, not code. Older classifier_inputs lack some
    # keys; only the keys present are compared.
    def evidence_drift(run, raw_case, inputs)
      return nil if inputs.empty?

      checks = {
        "agent_outcome" => -> { run.agent_outcome },
        "error_class" => -> { raw_case.dig("diagnostic", "error_class") },
        "step_kind" => -> { raw_case["step_kind"] },
        "host_pressure_level" => -> { raw_case["host_pressure_level"] },
        "job_log_kinds" => -> { raw_case["logs"].map { |log| log["kind"] }.compact },
        "spawned_process_outcomes" => -> { raw_case["spawned_processes"].map { |process| process["outcome"] }.compact.uniq }
      }
      checks.each do |key, current|
        next unless inputs.key?(key)

        recorded = inputs[key]
        now = current.call
        same = recorded.is_a?(Array) ? recorded.compact.map(&:to_s).sort == Array(now).map(&:to_s).sort : recorded == now
        return key unless same
      end
      nil
    end

    # The classifier's verdict on a case, computed on an unsaved Run whose
    # associations are preloaded with the case's inputs, so nothing is
    # written. Raw and sanitized inputs go through the same path, so whatever
    # this in-memory build cannot see (an explicit rate-limit log kind is a
    # database query) it misses equally for both.
    def verdict(run, kase)
      copy = Run.new(
        job_id: run.job_id,
        user_id: run.user_id,
        step_id: run.step_id,
        state: "failed",
        trigger_kind: kase.dig("run", "trigger_kind"),
        agent_provider: kase.dig("run", "agent_provider"),
        agent_outcome: kase.dig("run", "agent_outcome"),
        agent_summary: kase.dig("run", "agent_summary"),
        agent_pr_title: kase.dig("run", "agent_pr_title"),
        agent_pr_body: kase.dig("run", "agent_pr_body"),
        finished_at: run.finished_at,
        updated_at: run.updated_at
      )
      step = run.step
      workflow = step&.workflow
      original_reason = workflow&.failure_reason
      workflow.failure_reason = kase.dig("workflow", "failure_reason") if workflow
      if step
        # An unsaved stand-in, so the case's grader details (not the live
        # row's) are what GraderFailureSignal reads.
        step_copy = Step.new(kind: step.kind)
        step_copy.association(:workflow).target = workflow
        step_copy.details = kase["step_details"] || {}
        copy.association(:step).target = step_copy
      end

      preload(copy, :job_logs, kase["logs"].map { |log| JobLog.new(kind: log["kind"], chunk: log["chunk"]) })
      preload(copy, :spawned_processes, kase["spawned_processes"].map { |process| spawned_process(process) })
      if (diagnostic = kase["diagnostic"])
        attrs = diagnostic.slice("error_class", "error_message", "error_backtrace", "repo_snapshot")
        attrs["problem_code"] = diagnostic["problem_code"] if RunDiagnostic.column_names.include?("problem_code")
        attrs["problem_evidence"] = diagnostic["problem_evidence"] if RunDiagnostic.column_names.include?("problem_evidence")
        copy.association(:run_diagnostic).target = RunDiagnostic.new(attrs)
      end
      if kase["host_pressure_level"]
        copy.association(:run_resource_summary).target = RunResourceSummary.new(host_pressure_level: kase["host_pressure_level"])
      end

      result = RunFailureClassifier.new(copy).classify
      [ result.classification, result.retryable == true ]
    ensure
      workflow.failure_reason = original_reason if workflow
    end

    # A grader step's own record of how it ended: RunFailureClassifier asks
    # GraderFailureSignal whether it timed out. The raw case carries every
    # detail, the sanitized one only the keys that signal reads -- so the
    # fidelity check also proves those keys are enough.
    GRADER_STEP_KINDS = %w[grader preflight_grader].freeze
    GRADER_DETAIL_KEYS = %w[timed_out exit_code output log stdout stderr].freeze

    def step_details(step)
      return nil unless step && GRADER_STEP_KINDS.include?(step.kind.to_s)

      details = step.details.to_h.stringify_keys
      return details if @scale.nil?

      details.slice(*GRADER_DETAIL_KEYS).to_h do |key, value|
        [ key, value.is_a?(String) ? clip(value, :chunk) : value ]
      end.presence
    end

    def preload(record, name, targets)
      association = record.association(name)
      association.target = targets
      association.loaded!
    end

    def spawned_process(process)
      cgroup = process["cgroup"]
      SpawnedProcess.new(
        kind: process["kind"],
        outcome: process["outcome"],
        command: process["command"],
        hostname: "replay-worker",
        started_at: Time.now - 300,
        finished_at: Time.now - 60,
        resource_attribution: cgroup && {
          "cgroup" => {
            "state" => cgroup["state"],
            "memory_events" => { "oom_kill" => cgroup["oom_kill"].to_i },
            "memory_events_after" => { "oom_kill" => cgroup["oom_kill_after"].to_i }
          }
        }
      )
    end

    def instance_identifiers
      names = []
      names.concat(Repository.distinct.pluck(:owner))
      names.concat(Repository.where.not(upstream_owner: nil).distinct.pluck(:upstream_owner)) if Repository.column_names.include?("upstream_owner")
      names.concat(Installation.distinct.pluck(:account_login)) if defined?(Installation)
      user_columns = %w[github_handle first_name last_name] & User.column_names
      names.concat(User.pluck(*user_columns).flatten) if user_columns.any?
      names.concat(User.pluck(:email_address).map { |email| email.to_s.split("@").first })
      names.compact.map(&:to_s).reject { |name| PRESERVED_WORDS.include?(name.downcase) }
    end

    def failed_runs
      Run.where(state: "failed")
        .where("finished_at >= ?", @since)
        .includes(:run_failure_classification, :run_diagnostic, step: :workflow)
    end

    # Round-robin across recorded classifications so a corpus of a few hundred
    # covers every verdict instead of being all grader failures.
    def select_balanced(buckets)
      by_class = Hash.new { |hash, key| hash[key] = [] }
      buckets.each_value do |cases|
        cases.each { |kase| by_class[kase.dig("recorded", "classification")] << kase }
      end
      queues = by_class.sort_by { |name, _| name.to_s }.map { |_, cases| cases.dup }
      selected = []
      while selected.size < @limit && queues.any?(&:any?)
        queues.each do |queue|
          break if selected.size >= @limit

          kase = queue.shift
          selected << kase if kase
        end
      end
      selected.sort_by { |kase| kase["id"] }
    end

    def logs_for(run, classified_at)
      @logs_cache ||= {}
      rows = (@logs_cache[[ run.id, classified_at ]] ||= begin
        scope = run.job_logs
        scope = scope.where("created_at <= ?", classified_at) if classified_at
        scope.reorder(sequence: :desc).limit(LOG_LIMIT).pluck(:kind, :chunk).reverse
      end)
      rows.map { |kind, chunk| { "kind" => kind, "chunk" => clip(chunk, :chunk).to_s } }
    end

    def processes_for(run, classified_at)
      return [] unless run.respond_to?(:spawned_processes)

      moment = classified_at || run.finished_at || Time.now
      run.spawned_processes
        .where("created_at <= ?", moment)
        .where("finished_at IS NULL OR finished_at >= ?", moment - PROCESS_WINDOW)
        .map do |process|
          cgroup = process.resource_attribution.to_h["cgroup"].to_h
          {
            "kind" => process.kind,
            "outcome" => process.outcome,
            "command" => clip(process.command, :command),
            "cgroup" => cgroup.empty? ? nil : {
              "state" => cgroup["state"],
              "oom_kill" => cgroup["memory_events"].to_h["oom_kill"].to_i,
              "oom_kill_after" => cgroup["memory_events_after"].to_h["oom_kill"].to_i
            }
          }.compact
        end
    end

    def resource_summary(run)
      run.respond_to?(:run_resource_summary) ? run.run_resource_summary : nil
    end

    def attempts_for(run)
      AutoRetryAttempt.where(run_id: run.id).order(:id).map do |attempt|
        {
          "retry_kind" => attempt.retry_kind,
          "failure_classification" => attempt.failure_classification,
          "performed" => attempt.performed_at.present?,
          "skipped_reason" => Redactor.truncate(Redactor.scrub(attempt.skipped_reason.to_s), 300).presence
        }
      end
    end

    def classifier_inputs(classification)
      inputs = classification.classifier_inputs
      inputs = JSON.parse(inputs) if inputs.is_a?(String)
      inputs.is_a?(Hash) ? inputs : {}
    rescue JSON::ParserError
      {}
    end

    def backtrace(text)
      return nil if text.blank?
      return text if @scale.nil?

      clip(text.to_s.lines.first(LIMITS[:backtrace_lines] * @scale).join, :message)
    end

    def clip(text, limit)
      return nil if text.nil?
      return text if @scale.nil?

      Redactor.truncate(Redactor.scrub(text), LIMITS.fetch(limit) * @scale)
    end

    def scrub_value(value)
      @scale.nil? ? value : Redactor.call(value)
    end

    def fingerprint(kase)
      parts = [
        kase.dig("recorded", "classification"),
        kase.dig("recorded", "retryable"),
        kase["step_kind"],
        kase.dig("workflow", "trigger_kind"),
        kase.dig("run", "agent_outcome"),
        kase.dig("run", "agent_provider").present?,
        kase.dig("diagnostic", "error_class"),
        kase.dig("diagnostic", "problem_code"),
        normalize(kase.dig("diagnostic", "error_message").to_s)[0, 160]
      ]
      Digest::SHA256.hexdigest(JSON.generate(parts))[0, 12]
    end

    def normalize(text)
      text.to_s
        .gsub(/\b[0-9a-f]{7,40}\b/i, "H")
        .gsub(/\d+/, "N")
        .gsub(/\s+/, " ")
        .strip
    end
  end
end
