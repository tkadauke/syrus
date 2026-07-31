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
    created_at: nil,
    artifacts: nil
  )
    Workflow.create!(
      job: job,
      user: job.user,
      trigger_kind: trigger_kind,
      agent_provider: job.agent_provider,
      state: state,
      started_at: started_at,
      finished_at: finished_at,
      created_at: created_at || started_at,
      artifacts: artifacts
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

    expect(result).to include(count: 1, sample_count: 1, confidence: "low", total_observed_count: 1)
    expect(result.fetch(:per_hour)).to eq(1.0)
    expect(result.dig(:series, :syrus_authored)).to include(count: 1, per_hour: 1.0)
    expect(result.dig(:series, :external)).to include(count: 0, confidence: "none")
    expect(result.dig(:series, :fork_review)).to include(count: 0, confidence: "none")
  end

  it "keeps mixed PR creation sources in separate series" do
    syrus_job = Factories.job_record(user: user, repository: repository, pr_number: 123, created_at: now - 30.minutes)
    external_job = Factories.job_record(
      user: user,
      repository: repository,
      pr_number: nil,
      external_pr_number: 456,
      created_at: now - 28.minutes
    )
    fork_review_job = Factories.job_record(
      user: user,
      repository: repository,
      pr_number: nil,
      fork_review_pr_number: 789,
      created_at: now - 26.minutes
    )

    [ syrus_job, external_job, fork_review_job ].each_with_index do |job, index|
      workflow = workflow_for(job, trigger_kind: "initial", started_at: now - (20 - index).minutes)
      step_for(workflow, kind: "pr_open", finished_at: now - (18 - index).minutes)
    end

    pr_creation = call.fetch(:windows).fetch("1h").fetch(:pr_creation)

    expect(pr_creation).to include(count: 1, total_observed_count: 3)
    expect(pr_creation.dig(:series, :syrus_authored)).to include(count: 1, sample_count: 1)
    expect(pr_creation.dig(:series, :external)).to include(count: 1, sample_count: 1)
    expect(pr_creation.dig(:series, :fork_review)).to include(count: 1, sample_count: 1)
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
    expect(output.fetch(:by_job)).to contain_exactly(
      include(
        job_id: job.id,
        pr_source: "unknown",
        commit_count: 1,
        sample_count: 1,
        diff_sample_count: 1,
        unavailable_sample_count: 0,
        additions: 2,
        deletions: 1,
        net: 1
      )
    )
  end

  it "keeps output sample sizes honest when run diffs are unavailable" do
    job = Factories.job_record(user: user, repository: repository, pr_number: 123, created_at: now - 40.minutes)
    workflow = workflow_for(job, trigger_kind: "initial")
    step = step_for(workflow, kind: "implement", finished_at: now - 25.minutes)
    run_for(job, step, head_sha: "b" * 40, step_agent_diff: "")

    output = call.fetch(:windows).fetch("1h").fetch(:output)

    expect(output.fetch(:loc)).to include(count: 0, sample_count: 0, confidence: "none", unavailable_sample_count: 1)
    expect(output.fetch(:by_job)).to contain_exactly(
      include(
        job_id: job.id,
        pr_source: "syrus_authored",
        commit_count: 1,
        sample_count: 1,
        diff_sample_count: 0,
        unavailable_sample_count: 1,
        additions: 0,
        deletions: 0,
        net: 0
      )
    )
  end

  it "defines landing throughput, merge-train size, latency, and landing waste for clean auto-merge and trains" do
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

    expect(window.dig(:landing, :landing_units)).to include(count: 2, per_hour: 2.0)
    expect(window.dig(:landing, :jobs_landed)).to include(count: 4, per_hour: 4.0)
    expect(window.dig(:landing, :attempts, :successful)).to include(count: 2)
    expect(window.dig(:landing, :unit_types, :auto_merge)).to include(landing_units: 1, jobs_landed: 1)
    expect(window.dig(:landing, :unit_types, :merge_train)).to include(landing_units: 1, jobs_landed: 3)
    expect(window.dig(:landing, :merge_train_size)).to include(sample_count: 1, average: 3, max: 3, values: [ 3 ])
    expect(window.dig(:landing, :approved_to_landing_latency_seconds))
      .to include(sample_count: 1, average: 30.minutes.to_i)
    expect(window.dig(:landing, :landing_start_to_closed_latency_seconds))
      .to include(sample_count: 1, average: 15.minutes.to_i)
    expect(window.dig(:landing_waste, :failed_landing_attempts_per_successful_landing))
      .to include(numerator: 1, denominator: 2, value: 0.5)
    expect(window.dig(:landing_waste, :failed_or_cancelled_landing_workflow_seconds)).to eq(5.minutes.to_i)
    expect(window.dig(:landing_waste, :rebase_churn_workflow_count)).to eq(1)
    expect(window.dig(:landing_waste, :landing_blocking_rebase_count)).to eq(1)
    expect(window.dig(:landing, :current_optimistic_capacity)).to include(
      sample_count: 1,
      average_successful_unit_wall_time_seconds: 15.minutes.to_i,
      estimated_landing_units_per_hour: 4.0,
      estimated_jobs_landed_per_hour: 4.0
    )
  end

  it "measures landing grader phase duration from landing workflow step timings" do
    job = Factories.job_record(user: user, repository: repository, state: "closed", pr_number: 124, finished_at: now - 5.minutes, closure_reason: "pr_merged")
    workflow = workflow_for(job, trigger_kind: "auto_merge", started_at: now - 30.minutes, finished_at: now - 5.minutes)
    step_for(workflow, kind: "mergeability_preflight", started_at: now - 30.minutes, finished_at: now - 28.minutes, position: 0)
    step_for(workflow, kind: "grader_fanout", started_at: now - 22.minutes, finished_at: now - 21.minutes, position: 1)
    step_for(workflow, kind: "grader", started_at: now - 21.minutes, finished_at: now - 11.minutes, position: 2)
    step_for(workflow, kind: "grader_collect", started_at: now - 11.minutes, finished_at: now - 10.minutes, position: 3)

    landing = call.fetch(:windows).fetch("1h").fetch(:landing)

    expect(landing.fetch(:grader_phase_duration_seconds)).to include(sample_count: 1, average: 12.minutes.to_i)
    expect(landing.fetch(:mergeability_rebase_wait_seconds)).to include(sample_count: 1, average: 2.minutes.to_i)
  end

  it "counts merge-train base-moved regrade attempts without marking them as failed cooldown waste" do
    epic = Factories.epic(user: user, repository: repository)
    train = MergeTrain.create!(
      epic: epic,
      repository: repository,
      base_branch: "main",
      state: "failed",
      failure_reason: "merge_train: base moved from old to new; rebuild required",
      finished_at: now - 10.minutes
    )
    member_job = Factories.job_record(user: user, repository: repository, state: "approved", issue_number: 301)
    MergeTrainMember.create!(merge_train: train, job: member_job, position: 0)
    workflow = workflow_for(
      member_job,
      trigger_kind: "merge_train",
      state: "failed",
      started_at: now - 25.minutes,
      finished_at: now - 10.minutes,
      artifacts: {
        "merge_train_id" => train.id,
        Steps::MergeTrainLand::STALE_BASE_ARTIFACT => {
          "reason" => "base_moved",
          "built_base_sha" => "old",
          "current_base_sha" => "new"
        }
      }
    )
    step_for(workflow, kind: "merge_train_rebase", state: "failed", started_at: now - 12.minutes, finished_at: now - 10.minutes)

    window = call.fetch(:windows).fetch("1h")

    expect(window.dig(:landing, :attempts, :failed)).to include(count: 1)
    expect(window.dig(:landing, :base_moved_regrade_count)).to eq(1)
    expect(window.dig(:landing_waste, :failed_train_cooldown_seconds)).to eq(0)
  end

  it "reports failed train cooldown waste when a failed train is cooling down" do
    epic = Factories.epic(user: user, repository: repository)
    train = MergeTrain.create!(
      epic: epic,
      repository: repository,
      base_branch: "main",
      state: "failed",
      failure_reason: "merge_train: integration conflict",
      finished_at: now - 10.minutes
    )
    2.times do |index|
      member_job = Factories.job_record(user: user, repository: repository, state: "implemented", issue_number: 310 + index)
      MergeTrainMember.create!(merge_train: train, job: member_job, position: index)
    end

    waste = call.fetch(:windows).fetch("1h").fetch(:landing_waste)

    expect(waste.fetch(:failed_or_cancelled_landing_workflow_count)).to eq(1)
    expect(waste.fetch(:failed_train_cooldown_seconds)).to eq(30.minutes.to_i)
    expect(waste.fetch(:failed_train_cooldown_remaining_seconds)).to eq(20.minutes.to_i)
  end

  it "counts skipped landing validation reuse as deferred attempt context" do
    job = Factories.job_record(user: user, repository: repository, state: "approved", pr_number: 124)
    workflow = workflow_for(
      job,
      trigger_kind: "auto_merge",
      state: "cancelled",
      started_at: now - 15.minutes,
      finished_at: now - 10.minutes
    )
    step_for(workflow, kind: "prepare", state: "cancelled", started_at: nil, finished_at: now - 10.minutes).tap do |step|
      step.update!(cancellation_reason: "landing_validation_cached")
    end

    window = call.fetch(:windows).fetch("1h")

    expect(window.dig(:landing, :attempts, :cancelled)).to include(count: 1)
    expect(window.dig(:landing, :attempts, :deferred)).to include(count: 1)
    expect(window.dig(:landing, :reused_landing_validation_count)).to eq(1)
  end

  it "defines the review funnel from feedback comments, feedback workflows, and approvals" do
    immediate = Factories.job_record(
      user: user,
      repository: repository,
      pr_number: 125,
      approved_at: now - 10.minutes,
      approved_via: "operator"
    )
    immediate_workflow = workflow_for(immediate, trigger_kind: "initial")
    step_for(immediate_workflow, kind: "pr_open", finished_at: now - 25.minutes)
    JobApproval.create!(job: immediate, user: user, approved_at: now - 10.minutes)
    PrReviewComment.create!(
      job: immediate,
      pr_type: "direct",
      comment_kind: "issue",
      github_comment_id: 2,
      actionable: false,
      comment_created_at: now - 18.minutes
    )

    reviewed = Factories.job_record(
      user: user,
      repository: repository,
      pr_number: 126,
      approved_at: now - 8.minutes,
      approved_via: "github_review"
    )
    reviewed_workflow = workflow_for(reviewed, trigger_kind: "initial")
    step_for(reviewed_workflow, kind: "pr_open", finished_at: now - 30.minutes)
    JobApproval.create!(job: reviewed, user: user, approved_at: now - 8.minutes)
    feedback_workflow = workflow_for(reviewed, trigger_kind: "pr_comment", created_at: now - 15.minutes)
    PrReviewComment.create!(
      job: reviewed,
      pr_type: "direct",
      comment_kind: "review",
      github_comment_id: 1,
      actionable: true,
      comment_created_at: now - 20.minutes,
      handling_workflow: feedback_workflow,
      handled_at: now - 12.minutes,
      actioned_at: now - 12.minutes
    )

    funnel = call.fetch(:windows).fetch("1h").fetch(:review_funnel)

    expect(funnel).to include(
      jobs_with_pr_feedback: 1,
      jobs_with_feedback_before_approval: 1,
      feedback_rounds: 1,
      jobs_approved_immediately_without_feedback: 1,
      approval_count: 2,
      approval_vote_count: 2,
      pr_opened_count: 2
    )
    expect(funnel.dig(:approval_sources, :operator)).to include(count: 1, confidence: "low")
    expect(funnel.dig(:approval_sources, :github_review)).to include(count: 1, confidence: "low")
    expect(funnel.dig(:approval_sources, :auto)).to include(count: 0, confidence: "none")
    expect(funnel.fetch(:feedback_rounds_by_job)).to contain_exactly(
      include(
        job_id: reviewed.id,
        round_count: 1,
        workflow_round_count: 1,
        comment_count: 1,
        review_comment_count: 1,
        first_feedback_at: (now - 20.minutes).iso8601,
        last_addressed_at: (now - 12.minutes).iso8601
      )
    )
    expect(funnel.fetch(:pr_open_to_first_feedback_seconds)).to include(sample_count: 1, average: 10.minutes.to_i)
    expect(funnel.fetch(:feedback_to_addressed_seconds)).to include(sample_count: 1, average: 8.minutes.to_i)
    expect(funnel.fetch(:pr_open_to_approval_seconds)).to include(sample_count: 2, average: 1_110)
    expect(funnel.fetch(:approval_latency_seconds)).to include(sample_count: 2, average: 1_110)
    expect(funnel.fetch(:approval_to_landing_start_seconds)).to include(sample_count: 0, confidence: "none")
  end

  it "counts issue-comment, review-comment, and fork-review feedback as per-job feedback rounds" do
    job = Factories.job_record(
      user: user,
      repository: repository,
      pr_number: 126,
      approved_at: now - 5.minutes,
      approved_via: "github_review"
    )
    workflow_for(job, trigger_kind: "pr_comment", created_at: now - 35.minutes)
    workflow_for(job, trigger_kind: "chat_feedback", created_at: now - 25.minutes)

    PrReviewComment.create!(
      job: job,
      pr_type: "direct",
      comment_kind: "issue",
      github_comment_id: 10,
      actionable: true,
      comment_created_at: now - 40.minutes
    )
    PrReviewComment.create!(
      job: job,
      pr_type: "direct",
      comment_kind: "review",
      github_comment_id: 11,
      actionable: true,
      comment_created_at: now - 35.minutes
    )
    PrReviewComment.create!(
      job: job,
      pr_type: "fork_review",
      comment_kind: "review",
      github_comment_id: 12,
      actionable: true,
      comment_created_at: now - 30.minutes
    )

    by_job = call.fetch(:windows).fetch("1h").dig(:review_funnel, :feedback_rounds_by_job)

    expect(call.fetch(:windows).fetch("1h").dig(:review_funnel, :feedback_rounds)).to eq(3)
    expect(by_job).to contain_exactly(
      include(
        job_id: job.id,
        round_count: 3,
        workflow_round_count: 2,
        comment_count: 3,
        issue_comment_count: 1,
        review_comment_count: 2,
        fork_review_comment_count: 1
      )
    )
  end

  it "counts repeated feedback loops from existing feedback workflows even when comment batches are sparse" do
    job = Factories.job_record(
      user: user,
      repository: repository,
      pr_number: 128,
      approved_at: now - 2.minutes,
      approved_via: "operator"
    )
    3.times do |index|
      workflow_for(job, trigger_kind: "pr_comment", created_at: now - (45 - (index * 10)).minutes)
    end
    PrReviewComment.create!(
      job: job,
      pr_type: "direct",
      comment_kind: "issue",
      github_comment_id: 20,
      actionable: true,
      comment_created_at: now - 45.minutes
    )

    funnel = call.fetch(:windows).fetch("1h").fetch(:review_funnel)

    expect(funnel.fetch(:feedback_rounds)).to eq(3)
    expect(funnel.fetch(:feedback_rounds_by_job)).to contain_exactly(include(job_id: job.id, round_count: 3, comment_count: 1))
  end

  it "separates auto-approval from operator approval where approved_via supports it" do
    operator_job = Factories.job_record(
      user: user,
      repository: repository,
      pr_number: 125,
      approved_at: now - 12.minutes,
      approved_via: "bulk"
    )
    auto_job = Factories.job_record(
      user: user,
      repository: repository,
      pr_number: 126,
      approved_at: now - 10.minutes,
      approved_via: "auto_rule"
    )
    unknown_job = Factories.job_record(
      user: user,
      repository: repository,
      pr_number: 127,
      approved_at: now - 8.minutes,
      approved_via: nil
    )

    [ operator_job, auto_job, unknown_job ].each do |job|
      JobApproval.create!(job: job, user: user, approved_at: job.approved_at)
    end

    sources = call.fetch(:windows).fetch("1h").dig(:review_funnel, :approval_sources)

    expect(sources.fetch(:operator)).to include(count: 1)
    expect(sources.fetch(:auto)).to include(count: 1)
    expect(sources.fetch(:unknown)).to include(count: 1)
    expect(sources.fetch(:github_review)).to include(count: 0)
  end

  it "excludes cancelled and no-change jobs from approval and no-feedback approval samples" do
    Factories.job_record(user: user, repository: repository, state: "closed", closure_reason: "cancelled", pr_number: 129)
    Factories.job_record(user: user, repository: repository, state: "no_change_needed")

    funnel = call.fetch(:windows).fetch("1h").fetch(:review_funnel)

    expect(funnel).to include(
      approval_count: 0,
      jobs_approved_immediately_without_feedback: 0,
      jobs_with_feedback_before_approval: 0
    )
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

  it "reports empty windows without smoothing sparse data into nonzero rates" do
    window = call.fetch(:windows).fetch("1h")

    expect(window.fetch(:pr_creation)).to include(count: 0, per_hour: 0.0, sample_count: 0, confidence: "none")
    expect(window.dig(:output, :commits)).to include(count: 0, per_hour: 0.0, sample_count: 0, confidence: "none")
    expect(window.dig(:output, :loc)).to include(count: 0, per_hour: 0.0, sample_count: 0, confidence: "none")
    expect(window.dig(:landing, :jobs_landed)).to include(count: 0, per_hour: 0.0, sample_count: 0, confidence: "none")
  end

  it "marks low-activity recent windows with low confidence" do
    job = Factories.job_record(user: user, repository: repository, pr_number: 123, created_at: now - 30.minutes)
    workflow = workflow_for(job, trigger_kind: "initial")
    step_for(workflow, kind: "pr_open", finished_at: now - 20.minutes)

    window = call.fetch(:windows).fetch("4h")

    expect(window.fetch(:pr_creation)).to include(count: 1, sample_count: 1, confidence: "low")
    expect(window.fetch(:pr_creation).fetch(:per_hour)).to eq(0.25)
  end

  it "reports active recent windows with higher confidence when sample size is large enough" do
    5.times do |index|
      job = Factories.job_record(user: user, repository: repository, issue_number: 300 + index, pr_number: 400 + index, created_at: now - 30.minutes)
      workflow = workflow_for(job, trigger_kind: "initial", started_at: now - (25 - index).minutes)
      step_for(workflow, kind: "pr_open", finished_at: now - (20 - index).minutes)
    end

    pr_creation = call.fetch(:windows).fetch("1h").fetch(:pr_creation)

    expect(pr_creation).to include(count: 5, sample_count: 5, confidence: "medium")
    expect(pr_creation.fetch(:per_hour)).to eq(5.0)
  end
end
