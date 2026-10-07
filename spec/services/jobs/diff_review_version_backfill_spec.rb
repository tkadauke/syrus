require "rails_helper"

RSpec.describe Jobs::DiffReviewVersionBackfill do
  let(:user) { Factories.user(github_token: nil) }
  let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets", default_branch: "main") }
  let(:logger) { instance_double(ActiveSupport::Logger, info: nil, warn: nil) }

  def legacy_job(agent_diff:, step_agent_diff: nil, base_sha: "branch-base", head_sha: "branch-head")
    job = Factories.job_with_run(
      user: user,
      repository: repo,
      branch_name: "syrus/issue-42",
      workflow_attrs: { state: "succeeded" },
      step_attrs: { kind: "implement", state: "succeeded" },
      run_attrs: {
        state: "succeeded",
        base_sha: base_sha,
        head_sha: head_sha,
        agent_diff: agent_diff,
        step_agent_diff: step_agent_diff
      }
    )
    job.update_columns(state: "closed", closure_reason: "pr_merged", finished_at: Time.current)
    job
  end

  it "creates a final snapshot from a stored successful Run diff and is idempotent" do
    diff = <<~DIFF
      diff --git a/app/models/widget.rb b/app/models/widget.rb
      index 1111111..2222222 100644
      --- a/app/models/widget.rb
      +++ b/app/models/widget.rb
      @@ -1 +1,2 @@
       class Widget
      +  def active? = true
    DIFF
    job = legacy_job(agent_diff: diff, step_agent_diff: "diff --git a/app/models/widget.rb b/app/models/widget.rb\n+step")
    service = described_class.new(logger: logger)

    first = service.call
    second = service.call

    expect(first).to have_attributes(checked: 1, created: 1, reused: 0, skipped: 0, errors: 0)
    expect(second).to have_attributes(checked: 1, created: 0, reused: 1, skipped: 0, errors: 0)
    expect(job.diff_review_versions.count).to eq(1)
    version = job.diff_review_versions.first
    expect(version).to have_attributes(
      source_key: DiffReviewVersions::FinalSnapshot::FINAL_SOURCE_KEY,
      label: "All changes",
      reason: "source_diff",
      base_sha: "branch-base",
      head_sha: "branch-head"
    )
    expect(version.files_snapshot).to contain_exactly(include(
      "path" => "app/models/widget.rb",
      "status" => "modified",
      "additions" => 1
    ))
  end

  it "does not create a bogus empty main-to-main All changes version when no trustworthy diff exists" do
    job = legacy_job(agent_diff: "", base_sha: "main", head_sha: "main")

    result = described_class.new(logger: logger).call

    expect(result).to have_attributes(checked: 1, created: 0, reused: 0, skipped: 1, errors: 0)
    expect(result.skips).to contain_exactly(include("job_id" => job.id, "reason" => "no_trustworthy_diff"))
    expect(job.diff_review_versions).to be_empty
  end

  it "uses the full stored Run diff instead of a later respond step-only diff" do
    initial_diff = <<~DIFF
      diff --git a/app/models/initial.rb b/app/models/initial.rb
      new file mode 100644
      index 0000000..1111111
      --- /dev/null
      +++ b/app/models/initial.rb
      @@ -0,0 +1 @@
      +class Initial; end
    DIFF
    full_feedback_diff = <<~DIFF
      diff --git a/app/models/initial.rb b/app/models/initial.rb
      new file mode 100644
      index 0000000..1111111
      --- /dev/null
      +++ b/app/models/initial.rb
      @@ -0,0 +1 @@
      +class Initial; end
      diff --git a/app/models/responded.rb b/app/models/responded.rb
      new file mode 100644
      index 0000000..2222222
      --- /dev/null
      +++ b/app/models/responded.rb
      @@ -0,0 +1 @@
      +class Responded; end
    DIFF
    respond_step_diff = <<~DIFF
      diff --git a/app/models/responded.rb b/app/models/responded.rb
      new file mode 100644
      index 0000000..2222222
      --- /dev/null
      +++ b/app/models/responded.rb
      @@ -0,0 +1 @@
      +class Responded; end
    DIFF
    job = Factories.job_with_run(
      user: user,
      repository: repo,
      branch_name: "syrus/issue-42",
      workflow_attrs: { state: "succeeded" },
      step_attrs: { kind: "implement", state: "succeeded" },
      run_attrs: {
        state: "succeeded",
        base_sha: "branch-base",
        head_sha: "initial-head",
        agent_diff: initial_diff,
        step_agent_diff: initial_diff
      }
    )
    feedback_workflow = Workflow.create!(job: job, user: user, trigger_kind: "chat_feedback", agent_provider: job.agent_provider, state: "succeeded")
    feedback_step = Step.create!(workflow: feedback_workflow, kind: "respond", position: 0, state: "succeeded")
    Run.create!(
      job: job,
      step: feedback_step,
      user: user,
      trigger_kind: "chat_feedback",
      agent_provider: job.agent_provider,
      state: "succeeded",
      base_sha: "initial-head",
      head_sha: "final-head",
      agent_diff: full_feedback_diff,
      step_agent_diff: respond_step_diff
    )
    job.update_columns(state: "closed", closure_reason: "pr_merged", finished_at: Time.current)

    result = described_class.new(logger: logger).call

    expect(result).to have_attributes(checked: 1, created: 1, skipped: 0, errors: 0)
    version = job.diff_review_versions.first
    expect(version).to have_attributes(base_sha: "initial-head", head_sha: "final-head")
    expect(version.files_snapshot.map { |file| file["path"] }).to contain_exactly(
      "app/models/initial.rb",
      "app/models/responded.rb"
    )
  end

  it "skips a historical Run that only has a step-scoped diff" do
    diff = <<~DIFF
      diff --git a/app/models/responded.rb b/app/models/responded.rb
      index 1111111..2222222 100644
      --- a/app/models/responded.rb
      +++ b/app/models/responded.rb
      @@ -1 +1,2 @@
       class Responded
      +  def fixed? = true
    DIFF
    job = legacy_job(agent_diff: nil, step_agent_diff: diff)

    result = described_class.new(logger: logger).call

    expect(result).to have_attributes(checked: 1, created: 0, reused: 0, skipped: 1, errors: 0)
    expect(result.skips).to contain_exactly(include("job_id" => job.id, "reason" => "no_trustworthy_diff"))
    expect(job.diff_review_versions).to be_empty
  end
end
