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
    Workflows::Rebase.instantiate(job: job, artifacts: artifacts).update!(state: "failed")
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
end
