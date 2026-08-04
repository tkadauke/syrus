module CiRepair
  class ManualRerun
    MAX_SAME_SHA_REPAIRS_WITHOUT_OVERRIDE = 2

    Result = Data.define(:job, :workflow, :run, :refresh, :cleared_handled_sha)

    def self.call(job:, reason:, clear_handled_sha: true, instructions: nil, override_repeated_sha: false, agent_provider: nil)
      new(
        job: job,
        reason: reason,
        clear_handled_sha: clear_handled_sha,
        instructions: instructions,
        override_repeated_sha: override_repeated_sha,
        agent_provider: agent_provider
      ).call
    end

    def initialize(job:, reason:, clear_handled_sha:, instructions:, override_repeated_sha:, agent_provider:)
      @job = job
      @reason = reason.to_s.strip
      @clear_handled_sha = clear_handled_sha != false
      @instructions = instructions.to_s.strip.presence
      @override_repeated_sha = override_repeated_sha == true
      @agent_provider = agent_provider.to_s.strip.presence
    end

    def call
      raise ArgumentError, "reason is required" if @reason.blank?
      raise ArgumentError, "Job is closed." unless @job.open?
      raise ArgumentError, "Job has no tracked PR." if (@job.pr_number.presence || @job.external_pr_number.presence).blank?
      raise ArgumentError, "A CI repair workflow is already active for this Job." if active_ci_repair?

      refresh = CheckRefresh.call(@job)
      raise ArgumentError, "Current PR checks are #{refresh.state}; no failing checks are available for a CI repair rerun." unless refresh.state == "failing"
      enforce_same_sha_limit!(refresh.head_sha)

      cleared = clear_handled_sha?(refresh.head_sha)
      @job.update!(last_ci_handled_sha: nil) if cleared

      workflow = Workflows::CiFailure.instantiate(
        job: @job,
        artifacts: artifacts_for(refresh),
        agent_provider: @agent_provider
      )
      run = StepDispatcher.start_workflow(workflow)
      raise ArgumentError, "CI repair workflow start was deferred." unless run

      @job.update!(last_ci_handled_sha: refresh.head_sha)
      Result.new(job: @job.reload, workflow: workflow, run: run, refresh: refresh, cleared_handled_sha: cleared)
    end

    private

    def active_ci_repair?
      @job.workflows.active.where(trigger_kind: "ci_failure").exists?
    end

    def enforce_same_sha_limit!(head_sha)
      return if @override_repeated_sha

      prior_count = @job.workflows.where(trigger_kind: "ci_failure").select do |workflow|
        workflow.artifact("head_sha") == head_sha
      end.size
      return if prior_count < MAX_SAME_SHA_REPAIRS_WITHOUT_OVERRIDE

      raise ArgumentError, "Job already has #{prior_count} CI repair workflows for #{head_sha[0, 12]}; pass override_repeated_sha: true to run another."
    end

    def clear_handled_sha?(head_sha)
      @clear_handled_sha && @job.last_ci_handled_sha == head_sha
    end

    def artifacts_for(refresh)
      {
        "head_sha" => refresh.head_sha,
        "failed_checks" => refresh.failed_checks.map { |check| CheckEnricher.call(check) },
        "manual_ci_repair" => {
          "reason" => @reason,
          "instructions" => @instructions,
          "requested_at" => Time.current.iso8601,
          "clear_handled_sha" => @clear_handled_sha,
          "override_repeated_sha" => @override_repeated_sha
        }.compact
      }
    end
  end
end
