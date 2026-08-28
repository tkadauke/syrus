require "rails_helper"

RSpec.describe Timeline::MacroQuery do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_record(user: user, repository: repository, state: "running", issue_title: "Fix the aqueducts") }

  def record_event(event_type:, workflow:, hostname:, pid:, occurred_at:)
    WorkflowActivity.synchronously do
      WorkflowActivity.record!(
        event_type: event_type,
        source: "spec",
        workflow: workflow,
        message: "spec event",
        occurred_at: occurred_at
      )
    end
    WorkflowActivityEvent.where(workflow_id: workflow.id, event_type: event_type)
      .order(id: :desc).first.update_columns(hostname: hostname, pid: pid)
  end

  it "groups workflow spans into lanes keyed by hostname+pid attributed from WorkflowActivityEvent" do
    workflow = Workflow.create!(
      job: job, trigger_kind: "initial", state: "running",
      started_at: 30.minutes.ago, worker_hostname: "worker-a"
    )
    record_event(event_type: "workflow_started", workflow: workflow, hostname: "worker-a", pid: 4242, occurred_at: 30.minutes.ago)

    result = described_class.call(from: 1.hour.ago, to: Time.current)

    lane = result[:lanes].find { |candidate| candidate[:hostname] == "worker-a" }
    expect(lane).to be_present
    expect(lane[:pid]).to eq(4242)
    expect(lane[:spans]).to contain_exactly(
      include(workflow_id: workflow.id, job_id: job.id, status: "running", job_title: "Fix the aqueducts")
    )
  end

  it "falls back to SpawnedProcess and then Workflow#worker_hostname when no activity event is attributed" do
    workflow_with_process = Workflow.create!(
      job: job, trigger_kind: "initial", state: "succeeded",
      started_at: 40.minutes.ago, finished_at: 20.minutes.ago
    )
    SpawnedProcess.create!(
      workflow: workflow_with_process, kind: "agent", command: "claude", hostname: "worker-b", pid: 777,
      started_at: 40.minutes.ago, finished_at: 20.minutes.ago
    )

    workflow_with_column_only = Workflow.create!(
      job: job, trigger_kind: "initial", state: "succeeded",
      started_at: 15.minutes.ago, finished_at: 10.minutes.ago, worker_hostname: "worker-c"
    )

    result = described_class.call(from: 1.hour.ago, to: Time.current)

    process_lane = result[:lanes].find { |candidate| candidate[:hostname] == "worker-b" }
    expect(process_lane[:pid]).to eq(777)
    expect(process_lane[:spans].map { |span| span[:workflow_id] }).to include(workflow_with_process.id)

    column_lane = result[:lanes].find { |candidate| candidate[:hostname] == "worker-c" }
    expect(column_lane[:pid]).to be_nil
    expect(column_lane[:spans].map { |span| span[:workflow_id] }).to include(workflow_with_column_only.id)
  end

  it "adds idle lanes for worker instances alive in-range with no attributed spans" do
    InstanceVersion.create!(hostname: "worker-idle", role: "worker", version: "abc123",
                             started_at: 50.minutes.ago, last_heartbeat_at: 1.minute.ago)

    result = described_class.call(from: 1.hour.ago, to: Time.current)

    idle_lane = result[:lanes].find { |candidate| candidate[:hostname] == "worker-idle" }
    expect(idle_lane).to be_present
    expect(idle_lane[:pid]).to be_nil
    expect(idle_lane[:spans]).to eq([])
    expect(idle_lane[:instance]).to include(hostname: "worker-idle")
  end

  it "filters by repository_id, epic_id, job_id, hostname, and status" do
    other_repository = Factories.repository(user: user)
    other_job = Factories.job_record(user: user, repository: other_repository, state: "running")
    epic = Factories.epic(user: user, repository: repository)
    epic_job = Factories.job_record(user: user, repository: repository, epic: epic, state: "running")

    matching = Workflow.create!(job: job, trigger_kind: "initial", state: "running", started_at: 10.minutes.ago, worker_hostname: "worker-x")
    wrong_repo = Workflow.create!(job: other_job, trigger_kind: "initial", state: "running", started_at: 10.minutes.ago, worker_hostname: "worker-x")
    wrong_status = Workflow.create!(job: job, trigger_kind: "initial", state: "failed", started_at: 10.minutes.ago, finished_at: 5.minutes.ago, worker_hostname: "worker-x")
    epic_matching = Workflow.create!(job: epic_job, trigger_kind: "initial", state: "running", started_at: 10.minutes.ago, worker_hostname: "worker-x")

    by_repo = described_class.call(from: 1.hour.ago, to: Time.current, repository_id: repository.id)
    span_ids = by_repo[:lanes].flat_map { |lane| lane[:spans].map { |span| span[:workflow_id] } }
    expect(span_ids).to include(matching.id, wrong_status.id, epic_matching.id)
    expect(span_ids).not_to include(wrong_repo.id)

    by_job = described_class.call(from: 1.hour.ago, to: Time.current, job_id: job.id)
    expect(by_job[:lanes].flat_map { |lane| lane[:spans].map { |span| span[:workflow_id] } }).to contain_exactly(matching.id, wrong_status.id)

    by_epic = described_class.call(from: 1.hour.ago, to: Time.current, epic_id: epic.id)
    expect(by_epic[:lanes].flat_map { |lane| lane[:spans].map { |span| span[:workflow_id] } }).to contain_exactly(epic_matching.id)

    by_status = described_class.call(from: 1.hour.ago, to: Time.current, status: "failed")
    expect(by_status[:lanes].flat_map { |lane| lane[:spans].map { |span| span[:workflow_id] } }).to contain_exactly(wrong_status.id)

    by_hostname = described_class.call(from: 1.hour.ago, to: Time.current, hostname: "worker-x")
    expect(by_hostname[:lanes].map { |lane| lane[:hostname] }.uniq).to eq([ "worker-x" ])
  end

  it "excludes workflows that have not started and reports them separately under pending, with blocked-reason explanation" do
    started = Workflow.create!(job: job, trigger_kind: "initial", state: "running", started_at: 5.minutes.ago, worker_hostname: "worker-a")
    queued = WorkUnits::Launcher.instantiate(kind: "initial", job: Factories.job_record(user: user, repository: repository, state: "queued"))
    queued.work_unit.block!(reason: "provider_availability", blocked_until: 10.minutes.from_now, details: { "provider" => "codex" })

    result = described_class.call(from: 1.hour.ago, to: Time.current)

    span_ids = result[:lanes].flat_map { |lane| lane[:spans].map { |span| span[:workflow_id] } }
    expect(span_ids).to include(started.id)
    expect(span_ids).not_to include(queued.id)

    pending_entry = result[:pending].find { |entry| entry[:workflow_id] == queued.id }
    expect(pending_entry[:blocked]).to include(
      blocked_reason: "provider_availability",
      blocked_details: { "provider" => "codex" },
      available: true,
      historical: false
    )
  end

  it "excludes spans entirely outside the requested time range" do
    outside = Workflow.create!(job: job, trigger_kind: "initial", state: "succeeded", started_at: 3.hours.ago, finished_at: 2.hours.ago, worker_hostname: "worker-a")

    result = described_class.call(from: 1.hour.ago, to: Time.current)

    span_ids = result[:lanes].flat_map { |lane| lane[:spans].map { |span| span[:workflow_id] } }
    expect(span_ids).not_to include(outside.id)
  end
end
