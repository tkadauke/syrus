module ManualAgenticRun
  class Enqueuer
    Result = Data.define(:job, :workflow, :run, :base_result)

    def self.call(job:, base:, instructions:, reason:, push: true, failed_workflow_id: nil, agent_provider: nil)
      new(
        job: job,
        base: base,
        instructions: instructions,
        reason: reason,
        push: push,
        failed_workflow_id: failed_workflow_id,
        agent_provider: agent_provider
      ).call
    end

    def initialize(job:, base:, instructions:, reason:, push:, failed_workflow_id:, agent_provider:)
      @job = job
      @base = base.to_s
      @instructions = instructions.to_s.strip
      @reason = reason.to_s.strip
      @push = push != false
      @failed_workflow_id = failed_workflow_id
      @agent_provider = agent_provider.to_s.strip.presence
    end

    def call
      validate!
      base_result = BaseSelection.for(@base).new(job: @job, payload: base_payload).resolve
      raise ArgumentError, base_result.message unless base_result.success?

      workflow = Workflows::ManualAgenticRun.instantiate(
        job: @job,
        artifacts: artifacts(base_result),
        agent_provider: @agent_provider
      )
      run = StepDispatcher.start_workflow(workflow)
      raise ArgumentError, "manual agentic run workflow start was deferred." unless run

      audit!(run, workflow, base_result)
      Result.new(job: @job.reload, workflow: workflow, run: run, base_result: base_result)
    end

    private

    def validate!
      raise ArgumentError, "reason is required" if @reason.blank?
      raise ArgumentError, "instructions are required" if @instructions.blank?
      raise ArgumentError, "Job is closed." unless @job.open?
      raise ArgumentError, "push requires an existing PR branch." if @push && @job.branch_name.blank?
      raise ArgumentError, "push requires an existing PR." if @push && (@job.pr_number.presence || @job.external_pr_number.presence).blank?
      raise ArgumentError, "fresh_checkout cannot push to the existing PR branch; use current_pr_branch or disable push." if @push && @base == "fresh_checkout"
      raise ArgumentError, "A manual agentic run is already active for this Job." if @job.workflows.active.where(trigger_kind: "manual_agentic_run").exists?
    end

    def base_payload
      { "failed_workflow_id" => @failed_workflow_id }.compact
    end

    def artifacts(base_result)
      base_result.artifacts.merge(
        "manual_agentic_run_instructions" => @instructions,
        "manual_agentic_run_reason" => @reason,
        "manual_agentic_run_push" => @push,
        "manual_agentic_run_requested_at" => Time.current.iso8601,
        "repair_action" => "manual_agentic_run",
        "repair_reason" => @reason
      )
    end

    def audit!(run, workflow, base_result)
      JobLog.append!(
        run: run,
        chunk: "[operator repair] started manual_agentic_run workflow ##{workflow.id}; base=#{@base}; source=#{base_result.message}; push=#{@push}; reason=#{@reason}; instructions=#{@instructions}",
        kind: "system"
      )
    end
  end
end
