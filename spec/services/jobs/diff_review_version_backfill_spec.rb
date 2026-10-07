require "rails_helper"

RSpec.describe Jobs::DiffReviewVersionBackfill do
  let(:user) { Factories.user(github_token: nil) }
  let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets", default_branch: "main") }
  let(:logger) { instance_double(ActiveSupport::Logger, info: nil, warn: nil) }

  def legacy_job(diff:, base_sha: "branch-base", head_sha: "branch-head")
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
        step_agent_diff: diff
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
    job = legacy_job(diff: diff)
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
    job = legacy_job(diff: "", base_sha: "main", head_sha: "main")

    result = described_class.new(logger: logger).call

    expect(result).to have_attributes(checked: 1, created: 0, reused: 0, skipped: 1, errors: 0)
    expect(result.skips).to contain_exactly(include("job_id" => job.id, "reason" => "no_trustworthy_diff"))
    expect(job.diff_review_versions).to be_empty
  end
end
