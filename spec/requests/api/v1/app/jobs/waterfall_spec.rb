require "rails_helper"

RSpec.describe "App API job execution waterfall", type: :request do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets", default_branch: "main") }
  let(:job) { Factories.job_record(user: user, repository: repo, state: "running", issue_title: "Fix the aqueducts") }

  def parse_body = JSON.parse(response.body)

  def build_workflow_with_step(for_job: job)
    workflow = Workflow.create!(
      job: for_job,
      trigger_kind: "initial",
      state: "running",
      started_at: 10.minutes.ago,
      worker_hostname: "worker-a",
      worker_storage_key: "wf-123-storage"
    )
    step = workflow.steps.create!(kind: "prepare", position: 0, state: "succeeded", started_at: 10.minutes.ago, finished_at: 9.minutes.ago)
    step.runs.create!(job: for_job, trigger_kind: "initial", state: "succeeded", iteration: 1, started_at: 10.minutes.ago, finished_at: 9.minutes.ago, user: user)
    workflow
  end

  it "returns Step/Run timing without worker-identity fields for a non-admin" do
    user.update!(global_role: "user")
    sign_in_as(user)
    workflow = build_workflow_with_step

    get "/api/v1/app/jobs/#{job.id}/waterfall", params: { workflow_id: workflow.id }

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body.dig("workflow", "id")).to eq(workflow.id)
    expect(body.dig("workflow", "status")).to eq("running")
    expect(body["workflow"]).not_to have_key("hostname")
    expect(body["workflow"]).not_to have_key("pid")
    expect(body["workflow"]).not_to have_key("worker_storage_key")
    expect(body["workflow"]).not_to have_key("queue_role")

    step_payload = body.fetch("steps").first
    expect(step_payload["status"]).to eq("succeeded")
    expect(step_payload["started_at"]).to be_present
    expect(step_payload).not_to have_key("hostname")
    expect(step_payload).not_to have_key("pid")
    expect(step_payload).not_to have_key("worker_storage_key")
    expect(step_payload).not_to have_key("queue_role")
    expect(step_payload.fetch("runs").first).to include("status" => "succeeded")
  end

  it "returns full worker-identity fields for an admin" do
    user.update!(global_role: "admin")
    sign_in_as(user)
    workflow = build_workflow_with_step

    get "/api/v1/app/jobs/#{job.id}/waterfall", params: { workflow_id: workflow.id }

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body.dig("workflow", "hostname")).to eq("worker-a")
    expect(body.dig("workflow", "worker_storage_key")).to eq("wf-123-storage")
    step_payload = body.fetch("steps").first
    expect(step_payload).to have_key("hostname")
    expect(step_payload).to have_key("worker_storage_key")
  end

  it "returns distributed Step placement, command spans, barriers, and matching Step admission blocks" do
    user.update!(global_role: "admin")
    sign_in_as(user)
    workflow = build_workflow_with_step
    fanout = workflow.steps.first
    fanout.update!(kind: "grader_fanout", state: "succeeded")
    snapshot = WorkflowSourceSnapshot.create!(
      workflow: workflow,
      creator_step: fanout,
      source_sha: "abc123456789",
      source_ref: "refs/heads/main",
      tree_sha: "tree123",
      published_at: Time.current
    )
    grader = workflow.steps.create!(
      kind: "grader",
      position: 1,
      state: "queued",
      placement_policy: "pinned_workflow_workspace",
      depends_on_ids: [ fanout.id ],
      details: {
        "name" => "rspec",
        "projected_target_label" => "//:grade/rspec",
        "source_snapshot_id" => snapshot.id,
        "source_snapshot" => { "id" => snapshot.id, "source_sha" => snapshot.source_sha, "source_ref" => snapshot.source_ref },
        "prepare_cache" => { "status" => "miss", "short_cache_key" => "cache123" }
      }
    )
    grader.update_column(:placement_policy, "immutable_source_checkout")
    run = grader.runs.create!(job: job, user: user, trigger_kind: "initial", state: "running", iteration: 1, started_at: 1.minute.ago)
    WorkflowStepWorkerSlot.create!(workflow: workflow, step: grader, run: run, worker_key: "storage:worker-a", worker_hostname: "worker-a", worker_storage_key: "worker-a")
    CommandSpan.create!(
      job: job,
      workflow: workflow,
      step: grader,
      run: run,
      sequence: 1,
      name: "bundle exec rspec",
      command_excerpt: "bundle exec rspec",
      started_at: 1.minute.ago,
      finished_at: 30.seconds.ago,
      duration_ms: 30_000,
      outcome: "succeeded"
    )
    collect = workflow.steps.create!(kind: "grader_collect", position: 2, state: "queued", depends_on_ids: [ grader.id ])
    workflow.update!(artifacts: {
      "workflow_step_worker_slot_admission" => {
        "step_id" => grader.id,
        "step_kind" => "grader",
        "reason" => "worker_slot_busy",
        "retry_at" => 30.seconds.from_now.iso8601
      }
    })

    get "/api/v1/app/jobs/#{job.id}/waterfall", params: { workflow_id: workflow.id }

    expect(response).to have_http_status(:ok)
    body = parse_body
    grader_payload = body.fetch("steps").detect { |step| step["id"] == grader.id }
    expect(grader_payload.fetch("placement")).to include(
      "policy" => "immutable_source_checkout",
      "projected_target_label" => "//:grade/rspec"
    )
    expect(grader_payload.fetch("source_snapshot")).to include("source_sha" => "abc123456789")
    expect(grader_payload.fetch("prepare_cache")).to include("status" => "miss", "short_cache_key" => "cache123")
    expect(grader_payload.fetch("worker")).to include("hostname" => "worker-a", "storage_key" => "worker-a")
    expect(grader_payload.fetch("admission_block")).to include("reason" => "worker_slot_busy", "phase_step_id" => grader.id)
    expect(grader_payload.fetch("runs").first.fetch("command_spans").first).to include("name" => "bundle exec rspec")

    collect_payload = body.fetch("steps").detect { |step| step["id"] == collect.id }
    expect(collect_payload.fetch("barrier")).to include(
      "waiting_on_step_ids" => [ grader.id ],
      "completed_count" => 0,
      "total_count" => 1,
      "pending_count" => 1
    )
  end

  it "rejects a workflow_id that belongs to a different Job" do
    sign_in_as(user)
    other_job = Factories.job_record(user: user, repository: repo, state: "running", issue_number: 43)
    other_workflow = build_workflow_with_step(for_job: other_job)

    get "/api/v1/app/jobs/#{job.id}/waterfall", params: { workflow_id: other_workflow.id }

    expect(response).to have_http_status(:not_found)
  end

  it "rejects a user without visibility into the Job" do
    outsider = Factories.user
    sign_in_as(outsider)
    workflow = build_workflow_with_step

    get "/api/v1/app/jobs/#{job.id}/waterfall", params: { workflow_id: workflow.id }

    expect(response).to have_http_status(:not_found)
  end
end
