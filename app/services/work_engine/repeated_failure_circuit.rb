require "digest"

module WorkEngine
  class RepeatedFailureCircuit
    THRESHOLD = 3
    TOP_STACK_FRAMES = 5
    PROBLEM_CODE = "application_error".freeze
    CIRCUIT = "repeated_failure_circuit".freeze

    Result = Data.define(:open, :fingerprint, :streak_count, :app_revision, :error_class, :error_message, :top_stack_frames) do
      def open? = open
    end

    def self.call(...) = new(...).call

    def initialize(run:, threshold: THRESHOLD)
      @run = run
      @threshold = threshold
    end

    def call
      current = fingerprint_for(run)
      return closed unless current

      Result.new(
        open: streak_for(current) >= threshold,
        fingerprint: current[:fingerprint],
        streak_count: streak_for(current),
        app_revision: current[:app_revision],
        error_class: current[:error_class],
        error_message: current[:error_message],
        top_stack_frames: current[:top_stack_frames]
      )
    end

    def open_attention_item!(result = call)
      return unless result.open?

      result = AttentionItems::Opener.call(
        problem: Problem[PROBLEM_CODE, evidence: evidence_for(result)],
        title: "Repeated automatic repair failure on #{job.slug}",
        summary: "Automatic retries are paused after #{result.streak_count} identical failures on #{result.app_revision}.",
        urgency: "urgent",
        actions: actions,
        job: job,
        workflow: run.workflow,
        step: run.step,
        signature: attention_signature
      )
      supersede_stale_attention_items!(survivor: result.decision || result.prior)
      result
    rescue StandardError => e
      Rails.logger.warn("[WorkEngine::RepeatedFailureCircuit] failed to open attention item for Run ##{run.id}: #{e.class}: #{e.message}")
      nil
    end

    private

    attr_reader :run, :threshold

    def closed
      Result.new(
        open: false,
        fingerprint: nil,
        streak_count: 0,
        app_revision: nil,
        error_class: nil,
        error_message: nil,
        top_stack_frames: []
      )
    end

    def streak_for(current)
      @streak_for ||= {}
      @streak_for[current[:fingerprint]] ||= begin
        count = 0
        recent_workflows.each do |workflow|
          break unless workflow.failed?

          candidate = latest_failed_run_for(workflow)
          break unless candidate

          candidate_fingerprint = fingerprint_for(candidate)
          break unless candidate_fingerprint
          break unless candidate_fingerprint[:fingerprint] == current[:fingerprint]

          count += 1
        end
        count
      end
    end

    def recent_workflows
      job.workflows
        .includes(steps: [ runs: [ :run_diagnostic, :run_failure_classification ] ])
        .terminal
        .where("workflows.finished_at IS NULL OR workflows.finished_at <= ?", run.workflow&.finished_at || run.finished_at || Time.current)
        .reorder(finished_at: :desc, updated_at: :desc, id: :desc)
    end

    def latest_failed_run_for(workflow)
      workflow.steps
        .flat_map(&:runs)
        .select(&:failed?)
        .max_by { |candidate| [ candidate.finished_at || candidate.updated_at || candidate.created_at, candidate.id ] }
    end

    def fingerprint_for(candidate)
      diagnostic = candidate.run_diagnostic
      return nil unless diagnostic

      error_class = diagnostic.error_class.to_s.squish
      error_message = diagnostic.error_message.to_s.squish
      return nil if error_class.blank? && error_message.blank?

      top_stack_frames = diagnostic.error_backtrace.to_s.lines.first(TOP_STACK_FRAMES).map { |line| line.to_s.squish }.reject(&:blank?)
      app_revision = diagnostic.environment_snapshot.to_h["GIT_SHA"].presence || SyrusVersion.current
      fingerprint = Digest::SHA256.hexdigest(
        [ app_revision, error_class, error_message, *top_stack_frames ].join("\n")
      )

      {
        fingerprint: fingerprint,
        app_revision: app_revision,
        error_class: error_class,
        error_message: error_message,
        top_stack_frames: top_stack_frames
      }
    end

    def evidence_for(result)
      {
        fingerprint: result.fingerprint,
        app_revision: result.app_revision,
        error_class: result.error_class,
        error_message: result.error_message,
        top_stack_frames: result.top_stack_frames,
        streak_count: result.streak_count,
        threshold: threshold,
        circuit: CIRCUIT,
        actionable_scope: "job:#{job.id}:#{CIRCUIT}",
        job_id: job.id,
        workflow_id: run.workflow_id,
        step_id: run.step_id,
        run_id: run.id,
        step_kind: run.step&.kind,
        trigger_kind: run.workflow&.trigger_kind
      }.compact
    end

    def actions
      [
        { "action_key" => "retry_job", "label" => "Retry manually after deploy or fix",
          "payload" => { "job_id" => job.id } }
      ].select { |action| known_action?(action["action_key"]) }
    end

    def known_action?(key)
      PendingActions.for(key)
      true
    rescue PendingActions::UnknownAction
      false
    end

    def attention_signature
      "#{PROBLEM_CODE}:#{CIRCUIT}:job:#{job.id}"
    end

    def supersede_stale_attention_items!(survivor:)
      stale_repeated_failure_items(survivor: survivor).each do |item|
        item.update!(state: "superseded")
      end
    end

    def stale_repeated_failure_items(survivor:)
      scope = AttentionItem
        .open_decisions
        .where(problem_code: PROBLEM_CODE, job_id: job.id, repository_id: job.repository_id)
      scope = scope.where.not(id: survivor.id) if survivor
      scope.select { |item| repeated_failure_attention_item?(item) }
    end

    def repeated_failure_attention_item?(item)
      evidence = item.evidence.to_h
      evidence["circuit"] == CIRCUIT ||
        (evidence.key?("threshold") && evidence.key?("fingerprint") && evidence.key?("streak_count"))
    end

    def job
      @job ||= run.job
    end
  end
end
