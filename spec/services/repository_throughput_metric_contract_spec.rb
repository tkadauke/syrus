require "rails_helper"

RSpec.describe RepositoryThroughputMetricContract do
  let(:now) { Time.zone.local(2026, 7, 31, 12, 0, 0) }
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  def workflow_for(
    job,
    trigger_kind:,
    state: "succeeded",
    started_at: now - 10.minutes,
    finished_at: now - 5.minutes,
    created_at: nil
  )
    Workflow.create!(
      job: job,
      user: job.user,
      trigger_kind: trigger_kind,
      agent_provider: job.agent_provider,
      state: state,
      started_at: started_at,
      finished_at: finished_at,
      created_at: created_at || started_at
    )
  end

  def step_for(
    workflow,
    kind:,
    state: "succeeded",
    started_at: now - 8.minutes,
    finished_at: now - 6.minutes,
    position: 0
  )
    Step.create!(
      workflow: workflow,
      kind: kind,
      position: position,
      state: state,
      started_at: started_at,
      finished_at: finished_at
    )
  end

  def run_for(job, step, attrs = {})
    Run.create!({
      job: job,
      user: job.user,
      step: step,
      trigger_kind: step.workflow.trigger_kind,
      agent_provider: job.agent_provider,
      state: "succeeded",
      started_at: step.started_at,
      finished_at: step.finished_at
    }.merge(attrs))
  end

  def call
    described_class.new(repository: repository, now: now).call
  end

  it "defines PR creation throughput from successful pr_open steps" do
    job = Factories.job_record(user: user, repository: repository, pr_number: 123, created_at: now - 30.minutes)
    workflow = workflow_for(job, trigger_kind: "initial")
    step_for(workflow, kind: "pr_open", finished_at: now - 20.minutes)

    result = call.fetch(:windows).fetch("1h").fetch(:pr_creation)

    expect(result).to include(count: 1, sample_count: 1, confidence: "low")
    expect(result.fetch(:per_hour)).to eq(1.0)
  end

  it "reports output commits and LOC from succeeded output run snapshots and diffs" do
    job = Factories.job_record(user: user, repository: repository, created_at: now - 40.minutes)
    workflow = workflow_for(job, trigger_kind: "initial")
    step = step_for(workflow, kind: "implement", finished_at: now - 25.minutes)
    run_for(
      job,
      step,
      head_sha: "a" * 40,
      step_agent_diff: <<~DIFF
        diff --git a/app.rb b/app.rb
        index 111..222 100644
        --- a/app.rb
        +++ b/app.rb
        @@ -1,2 +1,3 @@
        -old
        +new
        +another
      DIFF
    )

    output = call.fetch(:windows).fetch("1h").fetch(:output)

    expect(output.fetch(:commits)).to include(count: 1, per_hour: 1.0, sample_count: 1, confidence: "low")
    expect(output.fetch(:loc)).to include(count: 1, additions: 2, deletions: 1, net: 1, unavailable_sample_count: 0)
  end

  it "defines landing throughput, merge-train size, latency, and landing waste" do
    approved_at = now - 50.minutes
    landing_started_at = now - 20.minutes
    closed_at = now - 5.minutes
    job = Factories.job_record(
      user: user,
      repository: repository,
      state: "closed",
      pr_number: 124,
      approved_at: approved_at,
      finished_at: closed_at,
      closure_reason: "pr_merged"
    )
    workflow_for(job, trigger_kind: "auto_merge", started_at: landing_started_at, finished_at: closed_at)
    workflow_for(
      job,
      trigger_kind: "auto_merge",
      state: "failed",
      started_at: now - 40.minutes,
      finished_at: now - 35.minutes
    )
    workflow_for(
      job,
      trigger_kind: "rebase",
      state: "failed",
      started_at: now - 34.minutes,
      finished_at: now - 30.minutes
    )

    epic = Factories.epic(user: user, repository: repository)
    train = MergeTrain.create!(
      epic: epic,
      repository: repository,
      base_branch: "main",
      state: "succeeded",
      finished_at: now - 3.minutes
    )
    3.times do |index|
      member_job = Factories.job_record(user: user, repository: repository, issue_number: 200 + index)
      MergeTrainMember.create!(merge_train: train, job: member_job, position: index)
    end

    window = call.fetch(:windows).fetch("1h")

    expect(window.dig(:landing, :landing_units)).to include(count: 1, per_hour: 1.0)
    expect(window.dig(:landing, :jobs_landed)).to include(count: 1, per_hour: 1.0)
    expect(window.dig(:landing, :merge_train_size)).to include(sample_count: 1, average: 3, max: 3, values: [ 3 ])
    expect(window.dig(:landing, :approved_to_landing_latency_seconds))
      .to include(sample_count: 1, average: 30.minutes.to_i)
    expect(window.dig(:landing, :landing_start_to_closed_latency_seconds))
      .to include(sample_count: 1, average: 15.minutes.to_i)
    expect(window.dig(:landing_waste, :failed_landing_attempts_per_successful_landing))
      .to include(numerator: 1, denominator: 1, value: 1.0)
    expect(window.dig(:landing_waste, :failed_or_cancelled_landing_workflow_seconds)).to eq(5.minutes.to_i)
    expect(window.dig(:landing_waste, :rebase_churn_workflow_count)).to eq(1)
    expect(window.dig(:landing_waste, :landing_blocking_rebase_count)).to eq(1)
  end

  it "defines the review funnel from feedback comments, feedback workflows, and approvals" do
    immediate = Factories.job_record(
      user: user,
      repository: repository,
      pr_number: 125,
      approved_at: now - 10.minutes
    )
    immediate_workflow = workflow_for(immediate, trigger_kind: "initial")
    step_for(immediate_workflow, kind: "pr_open", finished_at: now - 25.minutes)
    JobApproval.create!(job: immediate, user: user, approved_at: now - 10.minutes)

    reviewed = Factories.job_record(
      user: user,
      repository: repository,
      pr_number: 126,
      approved_at: now - 8.minutes
    )
    reviewed_workflow = workflow_for(reviewed, trigger_kind: "initial")
    step_for(reviewed_workflow, kind: "pr_open", finished_at: now - 30.minutes)
    JobApproval.create!(job: reviewed, user: user, approved_at: now - 8.minutes)
    workflow_for(reviewed, trigger_kind: "pr_comment", created_at: now - 15.minutes)
    PrReviewComment.create!(
      job: reviewed,
      pr_type: "direct",
      comment_kind: "review",
      github_comment_id: 1,
      actionable: true,
      comment_created_at: now - 20.minutes
    )

    funnel = call.fetch(:windows).fetch("1h").fetch(:review_funnel)

    expect(funnel).to include(
      jobs_with_pr_feedback: 1,
      feedback_rounds: 1,
      jobs_approved_immediately_without_feedback: 1,
      approval_count: 2,
      approval_vote_count: 2,
      pr_opened_count: 2
    )
    expect(funnel.fetch(:approval_latency_seconds)).to include(sample_count: 2, average: 1_110)
  end

  it "keeps sparse windows honest with sample counts, confidence labels, and last-active fallback" do
    old_job = Factories.job_record(user: user, repository: repository, pr_number: 127, created_at: now - 2.days)
    old_workflow = workflow_for(old_job, trigger_kind: "initial", finished_at: now - 2.days)
    step_for(old_workflow, kind: "pr_open", finished_at: now - 2.days)

    result = call.fetch(:windows)

    expect(result.fetch("1h").dig(:pr_creation)).to include(count: 0, sample_count: 0, confidence: "none")
    expect(result.fetch("last_active").dig(:pr_creation)).to include(count: 1, sample_count: 1, confidence: "low")
    expect(Time.iso8601(result.fetch("last_active").dig(:range, :end))).to eq(now - 2.days)
  end
end
