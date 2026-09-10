require "rails_helper"
require "tmpdir"
require "fileutils"

RSpec.describe App::JobDetailPayload do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user) }

  def payload_for(job)
    described_class.build(job: job, user: user)
  end

  def workflows_payload_for(job)
    described_class.workflows(job: job, user: user)
  end

  def capture_sql
    queries = []
    callback = lambda do |_name, _started, _finished, _id, payload|
      next if payload[:cached] || payload[:name] == "SCHEMA"

      queries << payload[:sql]
    end

    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    queries
  end

  def attach_work_unit(workflow, member_jobs:, kind: workflow.trigger_kind, state: "running", blocked_reason: nil)
    primary = member_jobs.first
    intent = WorkIntent.create!(
      kind: kind,
      state: "requested",
      repository: primary.repository,
      scope_type: primary.epic_id.present? ? "epic" : "job",
      scope_id: primary.epic_id.presence || primary.id,
      actor: primary.user,
      source_type: "spec"
    )
    unit = WorkUnit.create!(
      work_intent: intent,
      kind: kind,
      state: state,
      repository: primary.repository,
      scope_type: intent.scope_type,
      scope_id: intent.scope_id,
      workflow: workflow,
      blocked_reason: blocked_reason,
      blocked_details: blocked_reason ? { "source" => "spec" } : {}
    )
    member_jobs.each_with_index do |job, index|
      unit.work_unit_members.create!(job: job, role: index.zero? ? "primary" : "member")
    end
    unit
  end

  it "serializes distributed placement metadata on the matching Step without turning sibling blocks into workflow-wide state" do
    job = Factories.job_record(user: user, repository: repo, state: "running")
    workflow = Workflow.create!(job: job, trigger_kind: "initial", state: "running", started_at: 5.minutes.ago)
    fanout = workflow.steps.create!(kind: "grader_fanout", position: 0, state: "succeeded", started_at: 5.minutes.ago, finished_at: 4.minutes.ago)
    snapshot = WorkflowSourceSnapshot.create!(
      workflow: workflow,
      creator_step: fanout,
      source_sha: "abc123456789",
      source_ref: "refs/heads/main",
      tree_sha: "tree123",
      published_at: Time.current
    )
    running_grader = workflow.steps.create!(
      kind: "grader",
      position: 1,
      state: "running",
      placement_policy: "pinned_workflow_workspace",
      depends_on_ids: [ fanout.id ],
      details: {
        "name" => "rspec",
        "projected_target_label" => "//:grade/rspec",
        "projected_target_fingerprint" => "target123456789",
        "source_snapshot_id" => snapshot.id,
        "source_snapshot" => { "id" => snapshot.id, "source_sha" => snapshot.source_sha, "source_ref" => snapshot.source_ref },
        "prepare_cache" => { "status" => "hit", "short_cache_key" => "cache123" },
        "immutable_source_checkout" => { "worker_hostname" => "worker-a", "worker_storage_key" => "storage-a" }
      }
    )
    running_grader.update_column(:placement_policy, "immutable_source_checkout")
    blocked_grader = workflow.steps.create!(
      kind: "grader",
      position: 2,
      state: "queued",
      placement_policy: "pinned_workflow_workspace",
      depends_on_ids: [ fanout.id ],
      details: { "name" => "eslint", "projected_target_label" => "//:grade/eslint" }
    )
    blocked_grader.update_column(:placement_policy, "immutable_source_checkout")
    collect = workflow.steps.create!(kind: "grader_collect", position: 3, state: "queued", depends_on_ids: [ running_grader.id, blocked_grader.id ])
    run = running_grader.runs.create!(job: job, user: user, trigger_kind: "initial", state: "running", iteration: 1, started_at: 3.minutes.ago)
    CommandSpan.create!(
      job: job,
      workflow: workflow,
      step: running_grader,
      run: run,
      sequence: 1,
      name: "rspec",
      command_excerpt: "bundle exec rspec",
      started_at: 2.minutes.ago
    )
    workflow.update!(artifacts: {
      "workflow_admission_decision" => {
        "phase_step_id" => blocked_grader.id,
        "phase_step_kind" => "grader",
        "reason" => "predicted_budget_pressure_high",
        "retry_at" => 30.seconds.from_now.iso8601
      }
    })

    workflow_payload = workflows_payload_for(job).fetch(:workflows).detect { |entry| entry.fetch(:id) == workflow.id }
    steps = workflow_payload.fetch(:steps).index_by { |step| step.fetch(:id) }

    expect(steps.fetch(running_grader.id).fetch(:placement)).to include(
      policy: "immutable_source_checkout",
      projected_target_label: "//:grade/rspec",
      projected_target_fingerprint: "target123456789"
    )
    expect(steps.fetch(running_grader.id).fetch(:source_snapshot)).to include(source_sha: "abc123456789")
    expect(steps.fetch(running_grader.id).fetch(:worker)).to include(hostname: "worker-a", storage_key: "storage-a")
    expect(steps.fetch(running_grader.id).fetch(:prepare_cache)).to include(status: "hit", short_cache_key: "cache123")
    expect(steps.fetch(running_grader.id).fetch(:admission_block)).to be_nil
    expect(steps.fetch(running_grader.id).fetch(:runs).first.fetch(:command_spans).first).to include(name: "rspec")

    expect(steps.fetch(blocked_grader.id).fetch(:admission_block)).to include(
      reason: "predicted_budget_pressure_high",
      phase_step_id: blocked_grader.id
    )
    expect(steps.fetch(collect.id).fetch(:barrier)).to include(
      waiting_on_step_ids: contain_exactly(running_grader.id, blocked_grader.id),
      completed_count: 0,
      total_count: 2,
      pending_count: 2
    )
  end
end
