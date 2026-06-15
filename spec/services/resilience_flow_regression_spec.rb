require "rails_helper"

RSpec.describe "resilience flow regressions" do
  let(:user) { Factories.user }
  let(:job) { Factories.job(user: user) }
  let(:workflow) { job.workflows.last }
  let(:step) { workflow.steps.find_by(kind: "implement") }
  let(:run) do
    step.runs.create!(job: job, trigger_kind: workflow.trigger_kind,
                      agent_provider: workflow.agent_provider).tap do |r|
      r.start!
      r.save!
    end
  end

  let(:handler_class) do
    Class.new(Steps::Base) do
      def call; nil; end
      public :run_agent
    end
  end

  def result(**attrs)
    AgentInvocation::Result.new(**{
      turns: 1,
      exit_status: 0,
      timed_out: false,
      is_error: false,
      outcome: "success",
      final_text: nil,
      session_id: nil
    }.merge(attrs))
  end

  def adapter_returning(result)
    instance_double(AgentProviders::Base, run: result).tap do |adapter|
      allow(adapter).to receive(:record_result!) do |agent_result, log:|
        updates = {}
        updates[:agent_turns] = agent_result.turns if agent_result.turns
        updates[:agent_outcome] = agent_result.outcome if agent_result.outcome
        run.update!(updates) if updates.any?
        agent_result
      end
    end
  end

  def handler_with_adapter(adapter)
    handler_class.new(run).tap do |handler|
      allow(handler).to receive(:workspace).and_return(instance_double(WorkflowWorkspace, path: Rails.root))
      allow(handler).to receive(:agent_adapter).and_return(adapter)
    end
  end

  it "classifies a silent Claude timeout without enqueueing duplicate retry work" do
    timeout = result(timed_out: true, outcome: "timeout", exit_status: nil)
    handler = handler_with_adapter(adapter_returning(timeout))

    expect {
      handler.run_agent(prompt: "keep aqueducts flowing")
    }.to raise_error(Steps::Base::StepFailed, "agent timed out")

    expect(run.reload.agent_outcome).to eq("timeout")
    expect(Workflow.where(job: job, trigger_kind: "retry")).to be_empty
  end

  it "classifies Codex turn_failed upstream API errors as agent errors" do
    codex_error = result(is_error: true, outcome: "turn_failed",
                         final_text: "upstream API error: 502 Bad Gateway")
    handler = handler_with_adapter(adapter_returning(codex_error))

    expect {
      handler.run_agent(prompt: "repair the marble route")
    }.to raise_error(Steps::Base::StepFailed, "agent reported turn_failed")

    expect(run.reload.agent_outcome).to eq("turn_failed")
    expect(run.agent_turns).to eq(1)
  end

  it "treats provider configuration failures as non-retry-created validation failures" do
    adapter = instance_double(AgentProviders::Base)
    allow(adapter).to receive(:run).and_raise(AgentProviders::ConfigurationError, "Codex API key is not configured")
    handler = handler_with_adapter(adapter)

    expect {
      handler.run_agent(prompt: "do the configured thing")
    }.to raise_error(Steps::Base::StepFailed, "Codex API key is not configured")

    expect(run.reload.agent_outcome).to be_nil
    expect(Workflow.where(job: job, trigger_kind: "retry")).to be_empty
  end

  it "exposes JobLog rate-limit signals through the app payload" do
    JobLog.append!(run: run, kind: "rate_limited",
                   chunk: "[rate-limited] core quota exhausted; resets soon")

    payload = App::JobDetailPayload.build(job: job, user: user)
    payload_run = payload.fetch(:workflows).flat_map { |wf| wf.fetch(:steps) }
                         .flat_map { |s| s.fetch(:runs) }
                         .find { |item| item.fetch(:id) == run.id }

    expect(payload_run).to include(rate_limited: true)
  end

  it "exposes classified failed runs and retry availability in the admin serializer" do
    run.update!(state: "failed", agent_outcome: "worker_died",
                started_at: 2.minutes.ago, finished_at: Time.current)
    run.create_run_diagnostic!(error_class: "SolidQueue::ProcessPrunedError",
                               error_message: "worker heartbeat lapsed")
    step.update!(state: "failed", started_at: 2.minutes.ago, finished_at: Time.current)
    workflow.update!(state: "failed", failure_count: 1,
                     started_at: 2.minutes.ago, finished_at: Time.current)

    payload = Admin::JobStateSerializer.workflow(workflow)
    payload_run = payload.fetch(:steps).flat_map { |s| s.fetch(:runs) }.find { |item| item.fetch(:id) == run.id }

    expect(payload).to include(state: "failed", failure_count: 1, retry_available: true)
    expect(payload_run).to include(state: "failed", agent_outcome: "worker_died")
    expect(payload_run.fetch(:run_diagnostic)).to include(error_class: "SolidQueue::ProcessPrunedError")
  end

  it "uses the newest failed run classification for the workflow-level admin payload" do
    first_failed_run = run
    second_failed_run = step.runs.create!(
      job: job,
      trigger_kind: workflow.trigger_kind,
      agent_provider: workflow.agent_provider,
      state: "failed",
      started_at: 4.minutes.ago,
      finished_at: 3.minutes.ago
    )

    first_failed_run.update_columns(
      state: "failed",
      started_at: 10.minutes.ago,
      finished_at: 9.minutes.ago
    )
    first_failed_run.create_run_failure_classification!(
      classification: "agent_timeout",
      confidence: 0.8,
      retryable: true,
      reason: "No agent heartbeat",
      diagnostic_summary: "Timed out",
      classifier_inputs: { "agent_outcome" => "timeout" },
      classified_at: 9.minutes.ago
    )
    second_failed_run.create_run_failure_classification!(
      classification: "worker_died",
      confidence: 0.95,
      retryable: true,
      reason: "Worker disappeared",
      diagnostic_summary: "Solid Queue process pruned",
      classifier_inputs: { "error_class" => "SolidQueue::ProcessPrunedError" },
      classified_at: 3.minutes.ago
    )
    step.update!(state: "failed", started_at: 10.minutes.ago, finished_at: 3.minutes.ago)
    workflow.update!(state: "failed", started_at: 10.minutes.ago, finished_at: 3.minutes.ago)

    payload = Admin::JobStateSerializer.workflow(workflow)

    expect(payload.fetch(:failure_classification)).to include(
      classification: "worker_died",
      confidence: 0.95,
      retryable: true,
      reason: "Worker disappeared",
      diagnostic_summary: "Solid Queue process pruned",
      classifier_inputs: { "error_class" => "SolidQueue::ProcessPrunedError" }
    )
    run_payloads = payload.fetch(:steps).flat_map { |s| s.fetch(:runs) }
    expect(run_payloads.find { |item| item.fetch(:id) == first_failed_run.id }.fetch(:failure_classification))
      .to include(classification: "agent_timeout")
    expect(run_payloads.find { |item| item.fetch(:id) == second_failed_run.id }.fetch(:failure_classification))
      .to include(classification: "worker_died")
  end

  it "keeps retry budget exhaustion scoped to the failed workflow" do
    AppSetting.current.update!(max_job_failures: 1)
    workflow.update!(state: "running", started_at: 1.minute.ago)

    expect {
      workflow.record_run_failure!
    }.to change { workflow.reload.failure_count }.from(0).to(1)

    expect(workflow.reload.state).to eq("failed")
    expect(job.reload.state).not_to eq("failed")
    expect(Workflow.where(job: job, trigger_kind: "retry")).to be_empty
  end

  it "does not auto-open a retry workflow when the provider circuit is unavailable" do
    user.update!(codex_api_key: nil, claude_oauth_token: nil)
    workflow.update!(state: "failed", started_at: 1.minute.ago, finished_at: Time.current)
    step.update!(state: "failed", started_at: 1.minute.ago, finished_at: Time.current)
    run.update!(state: "failed", started_at: 1.minute.ago, finished_at: Time.current,
                agent_outcome: "turn_failed")
    job.runs.where(state: %w[queued running]).find_each do |active_run|
      active_run.update!(state: "failed", started_at: 1.minute.ago, finished_at: Time.current)
    end

    result = RetryWorkflowEnqueuer.call(job: job, agent_provider: "codex",
                                        provider_validation: :configured)

    expect(result).not_to be_success
    expect(result.error).to eq("That agent is not available for retry.")
    expect(Workflow.where(job: job, trigger_kind: "retry")).to be_empty
  end
end
