require "rails_helper"

RSpec.describe App::JobRetryActions do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user) }

  def actions_for(job)
    described_class.for(job)
  end

  def build_failed_workflow(job, trigger_kind: "initial", failed_step_kind: "coverage_analyze")
    workflow = Workflow.create!(
      job: job,
      trigger_kind: trigger_kind,
      agent_provider: job.agent_provider,
      state: "failed",
      started_at: 2.minutes.ago,
      finished_at: 1.minute.ago
    )
    step = workflow.steps.create!(
      kind: failed_step_kind,
      position: 1,
      state: "failed",
      started_at: 2.minutes.ago,
      finished_at: 1.minute.ago
    )
    [ workflow, step ]
  end

  def classify_failure(step, classification:, retryable: false)
    run = Run.create!(job: step.workflow.job, step: step, trigger_kind: step.workflow.trigger_kind, state: "failed")
    RunFailureClassification.create!(
      run: run,
      classification: classification,
      classified_at: Time.current,
      retryable: retryable,
      confidence: 0.9,
      reason: "test classification"
    )
    run
  end

  describe "when a post-implementation step fails with a git_state_corrupt workspace" do
    it "offers Retry implementation and hides the doomed retry-in-place action" do
      job = Factories.job_record(user: user, repository: repo, state: "failed")
      _workflow, step = build_failed_workflow(job, failed_step_kind: "coverage_analyze")
      classify_failure(step, classification: "git_state_corrupt")

      actions = actions_for(job)

      expect(actions[:implementation]).to include(
        key: "retry_implementation",
        label: "Retry implementation",
        path: "/api/v1/app/jobs/#{job.id}/run_again"
      )
      expect(actions[:failed_step]).to be_nil
    end
  end

  describe "when a post-implementation step fails with a retryable, non-git classification" do
    it "keeps today's behavior: no implementation retry, retry-in-place is offered" do
      job = Factories.job_record(user: user, repository: repo, state: "failed")
      workflow, step = build_failed_workflow(job, failed_step_kind: "coverage_analyze")
      classify_failure(step, classification: "timeout", retryable: true)

      actions = actions_for(job)

      expect(actions[:implementation]).to be_nil
      expect(actions[:failed_step]).to include(
        key: "retry_failed_step",
        workflow_id: workflow.id,
        step_kind: "coverage_analyze"
      )
    end
  end

  describe "when a post-implementation step fails with no failure classification recorded" do
    it "keeps today's behavior: no implementation retry, retry-in-place is offered" do
      job = Factories.job_record(user: user, repository: repo, state: "failed")
      workflow, _step = build_failed_workflow(job, failed_step_kind: "coverage_analyze")

      actions = actions_for(job)

      expect(actions[:implementation]).to be_nil
      expect(actions[:failed_step]).to include(
        key: "retry_failed_step",
        workflow_id: workflow.id,
        step_kind: "coverage_analyze"
      )
    end
  end

  describe "when a grade loop failed" do
    it "labels the action as a grade-loop restart" do
      job = Factories.job_record(user: user, repository: repo, state: "failed")
      workflow = Workflow.create!(
        job: job,
        trigger_kind: "retry",
        agent_provider: job.agent_provider,
        state: "failed",
        chain_template: [
          {
            "type" => "retry_until",
            "max_iterations" => 2,
            "repair" => [ "implement" ],
            "check" => [ "grader_fanout", "grader_collect" ],
            "repair_first" => false
          }
        ],
        started_at: 2.minutes.ago,
        finished_at: 1.minute.ago
      )
      fanout = workflow.steps.create!(kind: "grader_fanout", position: 1, state: "succeeded", loop_id: "grade-loop")
      collect = workflow.steps.create!(kind: "grader_collect", position: 2, state: "failed", loop_id: "grade-loop")
      fanout.update!(next_step: collect)

      actions = actions_for(job)

      expect(actions[:failed_step]).to include(
        key: "retry_failed_step",
        label: "Restart grade loop",
        step_kind: "grader_fanout"
      )
    end
  end

  describe "when an implementation-shaped step fails with a git_state_corrupt workspace" do
    it "still offers implementation retry and still hides retry-in-place" do
      job = Factories.job_record(user: user, repository: repo, state: "failed")
      _workflow, step = build_failed_workflow(job, failed_step_kind: "implement")
      classify_failure(step, classification: "git_state_corrupt")

      actions = actions_for(job)

      expect(actions[:implementation]).to include(key: "retry_implementation")
      expect(actions[:failed_step]).to be_nil
    end
  end
end
