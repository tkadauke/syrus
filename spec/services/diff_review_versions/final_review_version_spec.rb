require "rails_helper"

RSpec.describe DiffReviewVersions::FinalReviewVersion do
  let(:job) { Factories.job_with_run }
  let(:workflow) { job.latest_workflow }
  let(:run) { job.initial_run }

  it "prefers the exact current run or workflow version over the job default" do
    default_version = DiffReviewVersions::Creator.call(
      job: job,
      workflow: workflow,
      run: nil,
      base_sha: "default-base",
      head_sha: "default-head",
      files: [ { path: "app/models/default.rb", status: "modified", additions: 1, deletions: 0 } ],
      reason: "initial"
    )
    run_version = DiffReviewVersions::Creator.call(
      job: job,
      workflow: workflow,
      run: run,
      base_sha: "run-base",
      head_sha: "run-head",
      files: [ { path: "app/models/run.rb", status: "modified", additions: 1, deletions: 0 } ],
      reason: "initial"
    )

    result = described_class.resolve(job: job, workflow: workflow, run: run)

    expect(result).to eq(run_version)
    expect(result).not_to eq(default_version)
  end

  it "falls back to the reviewable job-level default when a retry workflow has no current version" do
    implementation_version = DiffReviewVersions::Creator.call(
      job: job,
      workflow: workflow,
      run: run,
      base_sha: "implementation-base",
      head_sha: "implementation-head",
      files: [ { path: "app/models/job.rb", status: "modified", additions: 3, deletions: 1 } ],
      reason: "initial"
    )
    DiffReviewVersion.create!(
      job: job,
      version_index: DiffReviewVersion.next_index_for(job),
      base_sha: "main",
      head_sha: "main",
      source_key: "legacy-empty-all-changes",
      label: "All changes",
      reason: "source_diff",
      files_snapshot: [],
      metadata: { "range_kind" => "all_changes" }
    )
    retry_workflow = Workflow.create!(job: job, trigger_kind: "retry", agent_provider: job.agent_provider)
    review_step = Step.create!(workflow: retry_workflow, kind: "post_implementation_review", position: 2)
    review_run = Run.create!(job: job, step: review_step, trigger_kind: "retry", agent_provider: job.agent_provider)

    result = described_class.resolve(job: job, workflow: retry_workflow, run: review_run)

    expect(result).to eq(implementation_version)
  end

  it "does not fall back to another job's version" do
    other_job = Factories.job_with_run(repository: job.repository, user: job.user, issue_number: 43)
    DiffReviewVersions::Creator.call(
      job: other_job,
      workflow: other_job.latest_workflow,
      run: other_job.initial_run,
      base_sha: "other-base",
      head_sha: "other-head",
      files: [ { path: "app/models/other.rb", status: "modified", additions: 1, deletions: 0 } ],
      reason: "initial"
    )

    retry_workflow = Workflow.create!(job: job, trigger_kind: "retry", agent_provider: job.agent_provider)
    review_step = Step.create!(workflow: retry_workflow, kind: "post_implementation_review", position: 2)
    review_run = Run.create!(job: job, step: review_step, trigger_kind: "retry", agent_provider: job.agent_provider)

    expect(described_class.resolve(job: job, workflow: retry_workflow, run: review_run)).to be_nil
  end

  it "does not fall back when the run belongs to a different job than the requested review job" do
    DiffReviewVersions::Creator.call(
      job: job,
      workflow: workflow,
      run: run,
      base_sha: "base",
      head_sha: "head",
      files: [ { path: "app/models/job.rb", status: "modified", additions: 1, deletions: 0 } ],
      reason: "initial"
    )
    other_job = Factories.job_with_run(repository: job.repository, user: job.user, issue_number: 43)

    expect(described_class.resolve(job: job, workflow: workflow, run: other_job.initial_run)).to be_nil
  end
end
