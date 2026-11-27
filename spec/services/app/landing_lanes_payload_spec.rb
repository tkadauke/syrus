require "rails_helper"

RSpec.describe App::LandingLanesPayload do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user:, auto_merge_enabled: true, landing_concurrency: 2) }

  def approved_job(number)
    Factories.job_record(
      user:, repository:, issue_number: number, pr_number: number, state: "implemented"
    ).tap do |job|
      job.approve!(via: "github_review")
      job.update!(approved_at: number.minutes.ago, github_mergeable_state: "clean", mergeability_checked_at: Time.current)
    end
  end

  def payload(now: Time.current)
    described_class.call(repositories: Repository.where(id: repository.id), jobs: Job.where(repository_id: repository.id), now:)
  end

  it "reports configured slots including empty capacity and the approved backlog in landing order" do
    landing, second = approved_job(3), approved_job(2)
    waiting = approved_job(1)
    LandingQueueProcessor.call

    result = payload
    repo = result.fetch(:repositories).sole

    expect(result.fetch(:estimate_kind)).to eq("best_case")
    expect(repo).to include(landing_concurrency: 2, busy_lane_count: 2)
    expect(repo.fetch(:lanes).map { |lane| lane.fetch(:empty) }).to eq([ false, false ])

    # Free one lane so its configured empty slot remains visible and put a Job
    # back in the approved queue.
    second.workflows.last.work_unit.release_landing_locks!
    second.workflows.last.work_unit.update!(state: "succeeded")
    second.update!(state: "closed")
    repo = payload.fetch(:repositories).sole
    expect(repo).to include(busy_lane_count: 1)
    expect(repo.fetch(:lanes).map { |lane| lane.fetch(:empty) }).to eq([ false, true ])
    expect(repo.fetch(:approved_backlog)).to include(
      include(id: waiting.id, slug: waiting.slug, app_path: "/jobs/#{waiting.id}")
    )
    expect(repo.fetch(:lanes).first.dig(:anchor_job, :id)).to eq(landing.id)
  end

  it "detects repair rounds, rebasing, and multisect sub-lanes" do
    job = approved_job(1)
    LandingQueueProcessor.call
    workflow = job.workflows.last
    workflow.steps.update_all(state: "succeeded")
    rebase = Step.create!(workflow:, kind: "merge_train_rebase", state: "running", position: 100, iteration: 2)
    Step.create!(
      workflow:, kind: "merge_train_multisect_evaluate", state: "queued", position: 101, iteration: 2,
      details: { "role" => "section", "round" => 3 }
    )

    lane = payload.fetch(:repositories).sole.fetch(:lanes).first
    expect(lane).to include(phase: "reconcile", repair_round: 1, rebasing: true)
    expect(lane.dig(:multisect, :sub_lanes)).to include(include(role: "section", round: 3, state: "queued"))
    expect(rebase).to be_running
  end

  it "weights grading by expected runtime and uses history before the timeout fallback" do
    job = approved_job(1)
    LandingQueueProcessor.call
    workflow = job.workflows.last
    workflow.steps.update_all(state: "succeeded")
    now = Time.current
    fast = Step.create!(workflow:, kind: "grader", state: "succeeded", position: 100, started_at: now - 20, finished_at: now - 10,
      details: { "name" => "fast", "timeout_minutes" => 2 })
    slow = Step.create!(workflow:, kind: "grader", state: "running", position: 101, started_at: now - 50,
      details: { "name" => "slow", "timeout_minutes" => 10 })
    [ 80.0, 120.0, 100.0 ].each_with_index do |duration, index|
      GraderConclusion.create!(repository:, job:, workflow:, step: slow, commit_sha: "a#{index}", grader_fingerprint: "f#{index}",
        grader_name: "slow", status: "passed", duration_s: duration, checked_at: now - index.minutes)
    end

    lane = payload(now:).fetch(:repositories).sole.fetch(:lanes).first
    graders = lane.fetch(:graders).index_by { |grader| grader.fetch(:name) }
    expect(graders.dig("slow", :expected_seconds)).to eq(100.0)
    expect(graders.dig("slow", :progress)).to eq(0.5)
    expect(graders.dig("fast", :expected_seconds)).to eq(60.0)
    expect(lane.fetch(:best_case_remaining_seconds)).to eq(80) # 50s grader + collect/land tail.
    expect(lane.fetch(:progress)).to be_between(0.0, 1.0)
    expect(fast).to be_succeeded
  end

  it "reports carried graders but excludes them from a repair round denominator" do
    job = approved_job(1)
    LandingQueueProcessor.call
    workflow = job.workflows.last
    workflow.steps.update_all(state: "succeeded")
    workflow.set_artifact!(Steps::GraderFanout::CARRIED_FORWARD_ARTIFACT_KEY, [ { "name" => "carried" } ])
    Step.create!(workflow:, kind: "grader", state: "running", position: 100, iteration: 2, started_at: Time.current,
      details: { "name" => "rerun", "timeout_minutes" => 2 })

    lane = payload.fetch(:repositories).sole.fetch(:lanes).first
    expect(lane.fetch(:graders)).to include(include(name: "carried", carried: true, expected_seconds: 0.0))
    expect(lane.fetch(:repair_round)).to eq(1)
    expect(lane.fetch(:best_case_remaining_seconds)).to be <= 90
  end

  it "batch-loads lane units and grader runtime history" do
    first, second = approved_job(2), approved_job(1)
    LandingQueueProcessor.call
    [ first, second ].each_with_index do |job, index|
      workflow = job.workflows.last
      workflow.steps.update_all(state: "succeeded")
      Step.create!(
        workflow:, kind: "grader", state: "running", position: 100,
        details: { "name" => "grader-#{index}", "timeout_minutes" => 2 }
      )
    end

    queries = []
    subscriber = ->(_name, _started, _finished, _id, event) do
      queries << event[:sql] unless event[:name] == "SCHEMA" || event[:cached]
    end
    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { payload }

    unit_batch_queries = queries.grep(/FROM ["`]?work_units["`]?.*WHERE ["`]?work_units["`]?\.["`]?id["`]? IN/im)
    expect(unit_batch_queries.size).to eq(1)
    expect(queries.grep(/FROM \(SELECT .*grader_conclusions/im).size).to eq(1)
  end
end
