require "rails_helper"

RSpec.describe Steps::Manual, :ci_only do
  let(:job) { Factories.job }
  let(:workflow) { Workflows::Manual.instantiate(job: job) }
  let(:step) { workflow.steps.find_by!(kind: "manual") }
  let(:run) { step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, prompt: "Tighten the review UI copy.") }
  let(:handler) { described_class.new(run) }
  let(:workspace) { instance_double(WorkflowWorkspace, setup: nil, path: Pathname.new("/tmp/workspace")) }

  before do
    allow(handler).to receive(:workspace).and_return(workspace)
    allow(handler).to receive(:run_agent)
    allow(handler).to receive(:head_sha).and_return("base123", "head456")
    allow(handler).to receive(:diff_against_default).and_return(<<~DIFF)
      diff --git a/foo.rb b/foo.rb
      index 1111111..2222222 100644
      --- a/foo.rb
      +++ b/foo.rb
      @@ -1 +1,2 @@
       old
      +bar
    DIFF
    allow(handler).to receive(:diff_against_sha).with("base123").and_return(<<~DIFF)
      diff --git a/foo.rb b/foo.rb
      index 1111111..2222222 100644
      --- a/foo.rb
      +++ b/foo.rb
      @@ -1 +1,2 @@
       old
      +bar
    DIFF
  end

  it "captures a manual run diff review version when the branch changes" do
    handler.call

    version = job.diff_review_versions.sole
    expect(version).to have_attributes(
      base_sha: "base123",
      head_sha: "head456",
      trigger_kind: "manual",
      label: "Manual run",
      reason: "manual"
    )
    expect(run.reload.step_agent_diff).to include("+bar")
  end

  it "does not capture a version when there is no branch diff" do
    allow(handler).to receive(:diff_against_default).and_return("")

    handler.call

    expect(job.diff_review_versions).to be_empty
  end
end
