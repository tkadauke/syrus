require "rails_helper"
require "ostruct"

RSpec.describe RebaseAttemptGuard do
  let(:job) { Factories.job }

  def pr(head_sha: "head", base_sha: "base")
    OpenStruct.new(
      head: OpenStruct.new(sha: head_sha),
      base: OpenStruct.new(sha: base_sha)
    )
  end

  def failed_rebase!(pre_sha: nil, base_sha: nil)
    artifacts = {}
    if pre_sha || base_sha
      artifacts["auto_rebase_result"] = {
        "succeeded" => false,
        "reason" => "conflict",
        "pre_sha" => pre_sha,
        "base_sha" => base_sha
      }.compact
    end
    workflow = Workflows::Rebase.instantiate(job: job, artifacts: artifacts)
    workflow.steps.find_by!(kind: "agent_rebase").update!(state: "failed")
    workflow.update!(state: "failed")
    workflow
  end

  # A rebase workflow whose agent step SUCCEEDED but which then failed
  # terminally further down the chain -- the shape that escaped the cap.
  def failed_late_step!(step_kind: "force_push", retryable: false, classification: "application_error")
    workflow = Workflows::Rebase.instantiate(job: job)
    step = workflow.steps.find_by(kind: step_kind) ||
      Step.create!(workflow: workflow, kind: step_kind, position: 99)
    step.update!(state: "failed")
    run = Run.create!(job: job, step: step, trigger_kind: "rebase", state: "failed")
    RunFailureClassification.create!(
      run: run, classification: classification, retryable: retryable, confidence: 0.9,
      reason: "pinned by spec", classified_at: Time.current
    )
    workflow.update!(state: "failed", finished_at: Time.current)
    workflow
  end

  def failed_agent_rebase!(finished_at:, pre_sha: "head", base_sha: "base")
    workflow = Workflows::Rebase.instantiate(
      job: job,
      artifacts: {
        "auto_rebase_result" => {
          "succeeded" => false,
          "reason" => "conflict",
          "pre_sha" => pre_sha,
          "base_sha" => base_sha
        }
      }
    )
    workflow.steps.find_by!(kind: "agent_rebase").update!(state: "failed", finished_at: finished_at)
    workflow.update!(state: "failed", finished_at: finished_at)
    workflow
  end

  it "counts consecutive failed rebase workflows and resets after success" do
    (described_class::ATTEMPT_CAP - 1).times { failed_rebase! }

    expect(described_class.cap_reached?(job)).to eq(false)

    failed_rebase!
    expect(described_class.cap_reached?(job)).to eq(true)

    Workflows::Rebase.instantiate(job: job).update!(state: "succeeded")
    expect(described_class.cap_reached?(job)).to eq(false)
  end

  it "does not count stale failures for a different PR head or base" do
    described_class::ATTEMPT_CAP.times { failed_rebase!(pre_sha: "old-head", base_sha: "base") }

    expect(described_class.cap_reached?(job)).to eq(true)
    expect(described_class.cap_reached?(job, pr: pr(head_sha: "new-head", base_sha: "base"))).to eq(false)
  end

  it "does not count non-agent rebase failures toward the cap" do
    described_class::ATTEMPT_CAP.times do
      workflow = Workflows::Rebase.instantiate(job: job)
      workflow.first_step.update!(state: "failed")
      workflow.update!(state: "failed")
    end

    expect(described_class.cap_reached?(job)).to eq(false)
  end

  it "lets autonomous dispatch retry after the repeat-failure cooldown expires" do
    AppSetting.current.update!(rebase_failure_cooldown_minutes: 60)
    described_class::ATTEMPT_CAP.times do
      failed_agent_rebase!(finished_at: 61.minutes.ago)
    end

    expect(described_class.cap_reached?(job, pr: pr)).to eq(false)
  end

  it "does not make the cap permanent when the cooldown setting is disabled" do
    AppSetting.current.update!(rebase_failure_cooldown_minutes: 0)
    described_class::ATTEMPT_CAP.times { failed_agent_rebase!(finished_at: 10.minutes.ago) }

    expect(described_class.cap_reached?(job, pr: pr)).to eq(false)
  end

  it "cools down recent agent rebase failures for the same PR head and base" do
    AppSetting.current.update!(rebase_failure_cooldown_minutes: 60)
    failed_agent_rebase!(finished_at: 10.minutes.ago)

    expect(described_class.cooling_down?(job, pr: pr)).to eq(true)
  end

  it "does not cool down when the setting is 0" do
    AppSetting.current.update!(rebase_failure_cooldown_minutes: 0)
    failed_agent_rebase!(finished_at: 10.minutes.ago)

    expect(described_class.cooling_down?(job, pr: pr)).to eq(false)
  end

  it "does not cool down when the Job branch changed after the failure" do
    AppSetting.current.update!(rebase_failure_cooldown_minutes: 60)
    job.update!(branch_name: "syrus/old-branch")
    failed_agent_rebase!(finished_at: 10.minutes.ago)
    job.update!(branch_name: "syrus/new-branch")

    expect(described_class.cooling_down?(job, pr: pr)).to eq(false)
  end

  def failed_agent_rebase_with_classification!(retryable:, finished_at:, pre_sha: "head", base_sha: "base")
    workflow = failed_agent_rebase!(finished_at: finished_at, pre_sha: pre_sha, base_sha: base_sha)
    step = workflow.steps.find_by!(kind: "agent_rebase")
    run = Run.create!(
      job: job,
      step: step,
      trigger_kind: workflow.trigger_kind,
      state: "failed",
      agent_provider: workflow.agent_provider,
      finished_at: finished_at
    )
    run.create_run_failure_classification!(
      classification: "provider_auth_or_config",
      confidence: 0.8,
      retryable: retryable,
      reason: "Codex API key is not configured",
      classified_at: Time.current
    )
    workflow
  end

  it "keeps blocking a permanently misconfigured rebase past cooldown expiry" do
    AppSetting.current.update!(rebase_failure_cooldown_minutes: 60)
    failed_agent_rebase_with_classification!(retryable: false, finished_at: 61.minutes.ago)

    expect(described_class.cooling_down?(job, pr: pr)).to eq(true)
    expect(described_class.cap_reached?(job, pr: pr)).to eq(true)
  end

  it "does not permanently block a failure classified as retryable" do
    AppSetting.current.update!(rebase_failure_cooldown_minutes: 60)
    failed_agent_rebase_with_classification!(retryable: true, finished_at: 61.minutes.ago)

    expect(described_class.cooling_down?(job, pr: pr)).to eq(false)
  end

  it "keeps a permanent provider configuration block when the PR head or base changes" do
    AppSetting.current.update!(rebase_failure_cooldown_minutes: 60)
    failed_agent_rebase_with_classification!(retryable: false, finished_at: 61.minutes.ago, pre_sha: "old-head", base_sha: "base")

    expect(described_class.cooling_down?(job, pr: pr(head_sha: "new-head", base_sha: "new-base"))).to eq(true)
    expect(described_class.cap_reached?(job, pr: pr(head_sha: "new-head", base_sha: "new-base"))).to eq(true)
  end

  it "lifts a permanent provider configuration block after a successful rebase" do
    failed_agent_rebase_with_classification!(retryable: false, finished_at: 61.minutes.ago)
    Workflows::Rebase.instantiate(job: job).update!(state: "succeeded")

    expect(described_class.cooling_down?(job, pr: pr)).to eq(false)
  end

  describe "failures outside the agent step" do
    # One Job retried an identical non-retryable force_push refusal 16 times in
    # 24 hours. The scan stopped at the first workflow that had not failed in
    # the agent step, so the cap counted none of them.
    it "counts a non-retryable failure in a later step toward the cap" do
      3.times { failed_late_step! }

      expect(described_class.consecutive_failures(job)).to eq(3)
      expect(described_class.cap_reached?(job)).to be(true)
    end

    it "blocks permanently rather than waiting out a cooldown that cannot help" do
      failed_late_step!

      expect(described_class.cooling_down?(job)).to be(true)
    end

    # A dead worker in a late step genuinely may succeed next time, so it must
    # not accumulate toward a permanent block.
    it "does not count a retryable failure in a later step" do
      3.times { failed_late_step!(retryable: true, classification: "worker_died") }

      expect(described_class.consecutive_failures(job)).to eq(0)
      expect(described_class.cap_reached?(job)).to be(false)
    end
  end
end
