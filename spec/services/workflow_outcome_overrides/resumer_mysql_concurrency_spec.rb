require "rails_helper"

RSpec.describe WorkflowOutcomeOverrides::Resumer, "MySQL review supersession concurrency", :ci_only do
  self.use_transactional_tests = false

  before do
    skip "MySQL row locking is required" unless ActiveRecord::Base.connection.adapter_name == "Mysql2"
  end

  after do
    @job&.destroy!
    @user&.destroy!
    ActiveRecord::Base.connection_handler.clear_all_connections!
  end

  it "serializes a repair Run claim behind review supersession without deadlocking" do
    @user = Factories.user
    @job = Factories.job(user: @user)
    workflow = @job.workflows.last
    reviewed_sha = "d" * 40
    vote = {
      "iteration" => 1, "step_id" => 46, "run_id" => 47,
      "provider" => "codex", "model" => "gpt-5", "verdict" => "needs_work",
      "critique" => "False positive."
    }
    workflow.set_artifact!("adversarial_review_iterations", [ vote ])
    review = Step.create!(workflow:, kind: "adversarial_review", position: 40, state: "succeeded",
      iteration: 1, loop_id: "claim-race", details: { "reviewed_head_sha" => reviewed_sha })
    repair = Step.create!(workflow:, kind: "implement", position: 41, state: "queued",
      iteration: 2, loop_id: "claim-race")
    continuation = Step.create!(workflow:, kind: "summarize", position: 42)
    run = Run.create!(job: @job, step: repair, trigger_kind: workflow.trigger_kind)
    review.update!(next_step_id: repair.id)
    repair.update!(next_step_id: continuation.id)
    continuation.update!(depends_on_ids: [ repair.id ])
    override = record_review_override(workflow:, step: review, vote:, reviewed_sha:)

    supersession_locked = Queue.new
    release_supersession = Queue.new
    claim_started = Queue.new
    results = Queue.new
    allow_any_instance_of(WorkflowOutcomeOverrides::Resumers::Review)
      .to receive(:locked_loop_segment).and_wrap_original do |original|
        segment = original.call
        supersession_locked << true
        release_supersession.pop
        segment
      end

    supersession = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        result = described_class.call(override: WorkflowOutcomeOverride.find(override.id))
        results << [ :supersession, result.id ]
      end
    rescue StandardError => error
      results << [ :error, error ]
    end
    supersession_locked.pop

    claimant = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        claimed_run = Run.find(run.id)
        executor = RunJob.new
        executor.queue_name = "runs"
        executor.instance_variable_set(:@run, claimed_run)
        executor.instance_variable_set(:@step, claimed_run.step)
        executor.instance_variable_set(:@workflow, claimed_run.workflow)
        executor.instance_variable_set(:@job, claimed_run.job)
        claim_started << true
        results << [ :claim, executor.send(:acquire_run_execution!) ]
      end
    rescue StandardError => error
      results << [ :error, error ]
    end
    claim_started.pop
    expect(claimant.join(0.2)).to be_nil

    release_supersession << true
    [ supersession, claimant ].each { |thread| thread.join(10) || raise("review supersession concurrency timed out") }
    outcomes = 2.times.map { results.pop }.to_h
    raise outcomes.fetch(:error) if outcomes.key?(:error)

    expect(outcomes).to include(supersession: override.id, claim: false)
    expect(override.reload).to be_consumed
    expect(repair.reload).to be_skipped
    expect(run.reload).to be_cancelled
    expect(continuation.reload.runs.count).to eq(1)
  ensure
    release_supersession << true if supersession&.alive?
    supersession&.join
    claimant&.join
  end

  private

  def record_review_override(workflow:, step:, vote:, reviewed_sha:)
    identity = WorkflowOutcomeOverrides::ReviewVerdict.gate_identity(
      review_kind: "adversarial_review", panel_id: nil, vote:
    )
    digest = WorkflowOutcomeOverrides::ReviewVerdict.evidence_digest(vote)
    WorkflowOutcomeOverride.record!(
      gate_failure: { outcome: "failed", technically_overridable: true, structural: false,
                      gate_identity: identity, evidence_digest: digest },
      job: @job, workflow:, step:, actor: @user, gate_kind: "review", gate_identity: identity,
      candidate_head_sha: reviewed_sha, prompt_version: "adversarial_review", evidence_digest: digest,
      channel: "ui", reason: "Confirmed false positive", permission_decision: { "policy" => "allow" }
    )
  end
end
