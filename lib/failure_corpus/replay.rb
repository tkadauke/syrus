# frozen_string_literal: true

require "json"
require "securerandom"
require "yaml"

module FailureCorpus
  # Decision-drift check: replays the current code's failure decisions against
  # the exported production corpus and reports every verdict that changed.
  #
  # Two decisions are replayed for each case:
  #
  #   * RunFailureClassifier's classification and retryability (which also
  #     covers Problem::Kind retryability for steps that declared a Problem);
  #   * AutoRetryJob's retryability recheck, for each auto-retry attempt
  #     production recorded against the Run.
  #
  # A changed classification that keeps its retryability is reported only. A
  # retryability flip, or a recheck that now skips a retry production ran (or
  # runs one it skipped), fails the check unless allowlist.yml acknowledges
  # that exact change for that case with a reason. An acknowledgement whose
  # change no longer happens fails too -- the intentional fix it recorded has
  # regressed, or the entry is stale.
  #
  # Every acknowledgement carries a status, so the file can record a known
  # problem without pretending it is fine:
  #
  #   intentional          -- a deliberate fix; the new verdict is right.
  #   unreviewed           -- believed deliberate (a commit says so) but not
  #                           yet confirmed by whoever owns the decision.
  #   suspected_regression -- the new verdict looks wrong; acknowledged so the
  #                           check stays useful for new drift, and listed in
  #                           every report until it is fixed or reclassified.
  #
  # Rebuilding a case writes rows (one scratch Run graph, overwritten per
  # case), so callers run it inside a transaction they roll back.
  class Replay
    DEFAULT_DIR = File.expand_path("../../spec/fixtures/failure_corpus", __dir__)
    CASES_FILE = "cases.jsonl"
    # Hand-written cases for real failures the export could not keep (their
    # evidence was pruned before an export ran). bin/export-failure-corpus
    # rewrites CASES_FILE and never touches this one.
    SYNTHETIC_FILE = "synthetic.jsonl"
    ALLOWLIST_FILE = "allowlist.yml"
    HOST = "failure-corpus-replay"

    Verdict = Data.define(:classification, :retryable) do
      def to_s = "#{classification}/#{retryable ? 'retryable' : 'final'}"
    end

    # kind: "retryable" (flip), "classification" (same retryability) or
    # "recheck" (AutoRetryJob's skip decision). `to` is the string an
    # allowlist entry names to acknowledge it.
    Change = Data.define(:case_id, :kind, :from, :to, :summary, :acknowledgement) do
      def failing? = kind != "classification" && acknowledgement.nil?
      def transition = "#{from} -> #{to}"
      def acknowledged_by = acknowledgement&.fetch("reason")
      def status = acknowledgement&.fetch("status")
    end

    STATUSES = %w[intentional unreviewed suspected_regression].freeze
    MARKS = { "intentional" => "ok", "unreviewed" => "??", "suspected_regression" => "XX" }.freeze

    StaleAcknowledgement = Data.define(:case_id, :to, :reason, :problem)

    class Report
      attr_reader :case_count, :changes, :stale

      def initialize(case_count:, changes:, stale:)
        @case_count = case_count
        @changes = changes
        @stale = stale
      end

      def failures = changes.select(&:failing?)
      def ok? = failures.empty? && stale.empty?
      def acknowledged(status) = changes.select { |change| change.status == status }

      def to_s
        lines = [ "Replayed #{case_count} failure corpus cases: #{changes.size} changed verdicts, " \
                  "#{failures.size} unacknowledged, #{stale.size} stale acknowledgements." ]
        counts = STATUSES.map { |status| "#{acknowledged(status).size} #{status}" }.join(", ")
        lines << "Acknowledged: #{counts} (marks: ok intentional, ?? unreviewed, XX suspected regression, !! unacknowledged)."
        %w[retryable recheck classification].each do |kind|
          group = changes.select { |change| change.kind == kind }
          next if group.empty?

          lines << ""
          lines << heading(kind)
          group.group_by(&:transition).sort.each do |transition, members|
            lines << "  #{transition} (#{members.size})"
            members.filter_map(&:acknowledgement).uniq.each do |entry|
              lines << "    [#{entry['status']}] #{entry['reason'].gsub(/\s+/, ' ')}"
            end
            members.each do |change|
              mark = change.kind == "classification" ? "  " : MARKS.fetch(change.status, "!!")
              lines << "    #{mark} #{change.case_id}  #{change.summary}"
            end
          end
        end
        if stale.any?
          lines << ""
          lines << "Stale acknowledgements (allowlist.yml entries whose change no longer happens):"
          stale.each { |entry| lines << "  !! #{entry.case_id} expected #{entry.to}: #{entry.problem}" }
        end
        unless ok?
          lines << ""
          lines << "Review each !! line. If the change is intentional, acknowledge it in " \
                   "spec/fixtures/failure_corpus/allowlist.yml with the reason; otherwise it is a regression."
        end
        lines.join("\n")
      end

      private

      def heading(kind)
        {
          "retryable" => "Retryability flips (fail unless acknowledged):",
          "recheck" => "AutoRetryJob retryability-recheck flips (fail unless acknowledged):",
          "classification" => "Classification changes with unchanged retryability (informational):"
        }.fetch(kind)
      end
    end

    def self.load_cases(dir = DEFAULT_DIR)
      [ CASES_FILE, SYNTHETIC_FILE ].flat_map do |name|
        path = File.join(dir, name)
        next [] unless File.exist?(path)

        File.readlines(path, chomp: true).reject(&:empty?).map { |line| JSON.parse(line) }
      end
    end

    def self.load_allowlist(dir = DEFAULT_DIR)
      path = File.join(dir, ALLOWLIST_FILE)
      return [] unless File.exist?(path)

      Array(YAML.safe_load_file(path))
    end

    def self.call(dir: DEFAULT_DIR)
      new(cases: load_cases(dir), allowlist: load_allowlist(dir)).call
    end

    def initialize(cases:, allowlist: [], sandbox: nil)
      @cases = cases
      @acknowledgements = index_allowlist(allowlist)
      @sandbox = sandbox
    end

    def call
      sandbox = @sandbox || Sandbox.build
      changes = []
      observed = {}

      @cases.each do |kase|
        fresh, persisted = sandbox.replay(kase)
        # A verdict the classifier wrote is compared with what it decides for
        # the same failure today. One a repair wrote directly is compared with
        # what re-classifying leaves behind -- what AutoRetryJob's recheck
        # sees -- since persist! keeps a confident verdict over "unclassified".
        result = kase.dig("recorded", "source") == "external" ? persisted : fresh
        replayed = Verdict.new(classification: result.classification, retryable: result.retryable == true)
        recorded = Verdict.new(classification: kase.dig("recorded", "classification"), retryable: kase.dig("recorded", "retryable") == true)
        observed[kase["id"]] = [ replayed.to_s ]

        if replayed != recorded
          kind = replayed.retryable == recorded.retryable ? "classification" : "retryable"
          changes << change(kase, kase["id"], kind, recorded.to_s, replayed.to_s)
        end

        Array(kase["auto_retry_attempts"]).each_with_index do |attempt, index|
          recorded_skip = recorded_recheck_skip(attempt)
          next if recorded_skip.nil?

          replayed_skip = AutoRetryJob.retryability_recheck_skips?(
            retry_kind: attempt["retry_kind"],
            failure_classification: attempt["failure_classification"],
            fresh: persisted
          )
          to = recheck_label(replayed_skip)
          observed[kase["id"]] << to
          next if replayed_skip == recorded_skip

          changes << change(kase, "#{kase['id']}#attempt-#{index + 1}", "recheck", recheck_label(recorded_skip), to)
        end
      end

      Report.new(case_count: @cases.size, changes: changes, stale: stale_acknowledgements(observed, changes))
    end

    private

    def change(kase, case_id, kind, from, to)
      Change.new(
        case_id: case_id,
        kind: kind,
        from: from,
        to: to,
        summary: summary(kase),
        acknowledgement: acknowledgement_for(kase["id"], to)
      )
    end

    def recheck_label(skip) = skip ? "recheck:skip" : "recheck:retry"

    # What the recheck decided in production, when the attempt shows it:
    # skipped as no longer retryable, or performed (so the recheck let it
    # through). Any other outcome -- superseded, rescheduled, failed to
    # launch -- happened before or after the recheck and says nothing about it.
    def recorded_recheck_skip(attempt)
      reason = attempt["skipped_reason"].to_s
      return true if reason.start_with?(AutoRetryAttempt::NOT_RETRYABLE_SKIP_PREFIX)
      return false if attempt["performed"] == true

      nil
    end

    def summary(kase)
      diagnostic = kase["diagnostic"] || {}
      message = diagnostic["error_message"].to_s.gsub(/\s+/, " ").strip[0, 90]
      exported = kase["export_verdict"]
      exported = exported && Verdict.new(classification: exported["classification"], retryable: exported["retryable"] == true)
      [
        "step=#{kase['step_kind'] || '-'}",
        ("recorded-by=repair" if kase.dig("recorded", "source") == "external"),
        # The verdict the exporting release reached on these exact sanitized
        # inputs: when it differs from the recorded one, the change predates
        # the export; when it matches, it is code since the export.
        ("export=#{exported}" if exported),
        kase.dig("run", "agent_outcome").presence && "outcome=#{kase.dig('run', 'agent_outcome')}",
        diagnostic["problem_code"].presence && "problem=#{diagnostic['problem_code']}",
        diagnostic["error_class"].presence && "#{diagnostic['error_class']}: #{message}"
      ].compact.join(" ")
    end

    def index_allowlist(entries)
      entries.each_with_object({}) do |entry, index|
        reason = entry["reason"].to_s.strip
        raise ArgumentError, "allowlist entry without a reason: #{entry.inspect}" if reason.empty?

        to = entry["to"].to_s.strip
        raise ArgumentError, "allowlist entry without a `to` verdict: #{entry.inspect}" if to.empty?

        status = entry["status"].to_s.strip
        raise ArgumentError, "allowlist entry status must be one of #{STATUSES.join(', ')}: #{entry.inspect}" unless STATUSES.include?(status)

        Array(entry["cases"]).each do |case_id|
          (index[case_id.to_s] ||= []) << { "reason" => reason, "to" => to, "status" => status }
        end
      end
    end

    def acknowledgement_for(case_id, to)
      Array(@acknowledgements[case_id]).find { |entry| entry["to"] == to }
    end

    def stale_acknowledgements(observed, changes)
      changed = changes.map { |change| [ change.case_id.split("#").first, change.to ] }.to_set
      @acknowledgements.flat_map do |case_id, entries|
        entries.filter_map do |entry|
          problem =
            if !observed.key?(case_id)
              "no such case in the corpus"
            elsif !observed[case_id].include?(entry["to"])
              "now replays as #{observed[case_id].join(', ')}"
            elsif !changed.include?([ case_id, entry["to"] ])
              "the recorded verdict already matches; the acknowledgement is unnecessary"
            end
          StaleAcknowledgement.new(case_id: case_id, to: entry["to"], reason: entry["reason"], problem: problem) if problem
        end
      end
    end

    # One scratch Job/Workflow/Step/Run graph, rewritten in place for every
    # case: far cheaper than a graph per case, and it keeps the classifier on
    # its real database reads (recent logs, spawned processes, explicit
    # rate-limit logs, deploy and macOS-update lookups).
    class Sandbox
      def self.build
        user = User.create!(email_address: "failure-corpus-#{SecureRandom.hex(4)}@example.test", password: SecureRandom.hex(16))
        repository = Repository.create!(user: user, owner: "example", name: "failure-corpus-#{SecureRandom.hex(4)}")
        job = Job.create!(user: user, owner_user: user, repository: repository, issue_number: 1)
        job.advance_after_triage! if job.may_advance_after_triage?
        run = job.reload.initial_run
        raise "failure corpus sandbox has no initial run" unless run&.step&.workflow

        new(run)
      end

      def initialize(run)
        @run = run
        @step = run.step
        @workflow = run.step.workflow
        @default_trigger_kind = @workflow.trigger_kind
      end

      # [fresh, persisted]: the classifier's verdict on the case as a new
      # failure, and the record RunFailureClassifier.persist! leaves when it
      # re-classifies over the verdict production recorded (what AutoRetryJob's
      # recheck acts on).
      def replay(kase)
        apply(kase)
        fresh = RunFailureClassifier.classify(Run.find(@run.id))

        recorded = kase["recorded"] || {}
        RunFailureClassification.insert!({
          run_id: @run.id,
          classification: recorded["classification"],
          retryable: recorded["retryable"] == true,
          confidence: recorded["confidence"],
          # Who wrote the verdict decides whether persist! may re-derive it.
          classifier_inputs: seeded_inputs(recorded, kase),
          classified_at: Time.current,
          created_at: Time.current,
          updated_at: Time.current
        })
        persisted = RunFailureClassifier.persist!(Run.find(@run.id))
        [ fresh, persisted ]
      end

      private

      def seeded_inputs(recorded, kase)
        if recorded["source"] == "external"
          RunFailureClassification.repair_inputs("failure_corpus:recorded")
        else
          { "run_state" => "failed", "step_kind" => kase["step_kind"] }
        end
      end

      def apply(kase)
        now = Time.current
        reset!

        run_attrs = kase["run"] || {}
        workflow_attrs = kase["workflow"] || {}
        if kase["step_kind"].present?
          @step.update_details_columns!(kase["step_details"] || {}, kind: kase["step_kind"])
          @workflow.update_columns(
            trigger_kind: workflow_attrs["trigger_kind"].presence || @default_trigger_kind,
            failure_reason: workflow_attrs["failure_reason"],
            worker_hostname: HOST
          )
        end
        @run.update_columns(
          state: "failed",
          step_id: kase["step_kind"].present? ? @step.id : nil,
          trigger_kind: run_attrs["trigger_kind"].presence || @run.trigger_kind,
          agent_provider: run_attrs["agent_provider"].to_s,
          agent_outcome: run_attrs["agent_outcome"],
          agent_summary: run_attrs["agent_summary"],
          agent_pr_title: run_attrs["agent_pr_title"],
          agent_pr_body: run_attrs["agent_pr_body"],
          finished_at: now,
          updated_at: now
        )

        insert_diagnostic(kase["diagnostic"], now)
        insert_logs(kase["logs"], now)
        insert_processes(kase["spawned_processes"], now)
        insert_resource_summary(kase["host_pressure_level"], run_attrs, now)
        insert_context(kase["context"] || {}, now)
      end

      def reset!
        RunDiagnostic.where(run_id: @run.id).delete_all
        JobLog.where(run_id: @run.id).delete_all
        SpawnedProcess.where(run_id: @run.id).delete_all
        RunResourceSummary.where(run_id: @run.id).delete_all
        RunFailureClassification.where(run_id: @run.id).delete_all
        InstanceVersion.where(hostname: [ "#{HOST}-a", "#{HOST}-b" ]).delete_all
        MacosWorkerDrain.where(hostname: HOST).delete_all
      end

      def insert_diagnostic(diagnostic, now)
        return if diagnostic.blank? || diagnostic["error_class"].blank?

        RunDiagnostic.insert!({
          run_id: @run.id,
          error_class: diagnostic["error_class"],
          error_message: diagnostic["error_message"],
          error_backtrace: diagnostic["error_backtrace"],
          problem_code: diagnostic["problem_code"],
          problem_evidence: diagnostic["problem_evidence"],
          repo_snapshot: diagnostic["repo_snapshot"],
          created_at: now,
          updated_at: now
        })
      end

      def insert_logs(logs, now)
        rows = Array(logs).each_with_index.filter_map do |log, index|
          next if log["chunk"].to_s.empty?

          { run_id: @run.id, sequence: index + 1, kind: log["kind"], chunk: log["chunk"], created_at: now, updated_at: now }
        end
        JobLog.insert_all!(rows) if rows.any?
      end

      def insert_processes(processes, now)
        rows = Array(processes).map do |process|
          cgroup = process["cgroup"]
          attribution = cgroup && {
            "cgroup" => {
              "state" => cgroup["state"],
              "memory_events" => { "oom_kill" => cgroup["oom_kill"].to_i },
              "memory_events_after" => { "oom_kill" => cgroup["oom_kill_after"].to_i }
            }
          }
          {
            run_id: @run.id,
            workflow_id: @workflow.id,
            job_id: @run.job_id,
            kind: process["kind"],
            outcome: process["outcome"],
            command: process["command"].presence || process["kind"],
            hostname: HOST,
            started_at: now - 5.minutes,
            finished_at: now - 1.minute,
            resource_attribution: attribution,
            created_at: now,
            updated_at: now
          }
        end
        SpawnedProcess.insert_all!(rows) if rows.any?
      end

      def insert_resource_summary(level, run_attrs, now)
        return if level.blank?

        RunResourceSummary.insert!({
          run_id: @run.id,
          job_id: @run.job_id,
          workflow_id: @workflow.id,
          step_id: @step.id,
          user_id: @run.user_id,
          agent_provider: run_attrs["agent_provider"].presence || "claude",
          trigger_kind: run_attrs["trigger_kind"].presence || @run.trigger_kind,
          host_sample_confidence: "sufficient",
          host_pressure_level: level,
          host_pressure_reasons: [],
          summary_version: RunResourceSummary::SUMMARY_VERSION,
          created_at: now,
          updated_at: now
        })
      end

      # The two environmental lookups the classifier makes are recorded as
      # booleans at classification time; recreate the minimal rows that make
      # each lookup answer the same way.
      def insert_context(context, now)
        if context["deploy_rollover_near_failure"]
          InstanceVersion.insert_all!(%w[a b].map do |suffix|
            { hostname: "#{HOST}-#{suffix}", role: "worker", version: "replay-#{suffix}", started_at: now, created_at: now, updated_at: now }
          end)
        end
        if context["macos_worker_update_near_failure"]
          MacosWorkerDrain.insert!({ hostname: HOST, state: "draining", drain_started_at: now, created_at: now, updated_at: now })
        end
      end
    end
  end
end
