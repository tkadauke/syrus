require "rails_helper"

RSpec.describe Admin::ResourceAdmissionDiagnosticsPayload do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, name: "syrus") }
  let(:now) { Time.zone.parse("2026-08-04T12:00:00Z") }

  def workflow_graph(state: "running", priority: "medium")
    job = Factories.job_record(user: user, repository: repository, state: "running", priority: priority, issue_title: "Resource job")
    workflow = Workflow.create!(job: job, user: user, trigger_kind: "initial", agent_provider: "codex", state: state)
    step = Step.create!(workflow: workflow, kind: "grader", position: 0, state: state == "running" ? "running" : "queued", details: { "name" => "rspec" })
    run = step.runs.create!(
      job: job,
      user: user,
      trigger_kind: workflow.trigger_kind,
      agent_provider: "codex",
      state: state == "running" ? "running" : "queued",
      started_at: now - 5.minutes,
      last_heartbeat_at: now - 30.seconds
    )
    [ job, workflow, step, run ]
  end

  def resource_summary_for(run, finished_at: now - 2.minutes)
    RunResourceSummary.create!(
      run: run,
      job: run.job,
      workflow: run.step.workflow,
      step: run.step,
      repository: repository,
      user: user,
      agent_provider: "codex",
      trigger_kind: run.trigger_kind,
      step_kind: run.step.kind,
      grader_name: "rspec",
      hostname: "worker-a",
      started_at: run.started_at,
      finished_at: finished_at,
      duration_seconds: 300,
      process_attributed_duration_seconds: 240,
      host_sample_count: 4,
      host_sample_confidence: "sufficient",
      host_pressure_max_cpu_some_percent: 76.5,
      host_pressure_max_io_some_percent: 44.1,
      host_usage_max_memory_used_percent: 68.0,
      host_pressure_level: "warning",
      host_pressure_reasons: [ "high CPU pressure" ],
      process_attribution_method: "test",
      process_attribution_version: 1,
      process_attribution_confidence: "high",
      process_attributed_sample_count: 3,
      process_attributed_cpu_seconds: 90.0,
      process_attributed_io_bytes: 123_456,
      process_attributed_memory_bytes: 512.megabytes,
      summary_version: RunResourceSummary::SUMMARY_VERSION
    )
  end

  def profile
    WorkflowStepResourceProfile.create!(
      repository: repository,
      agent_provider: "codex",
      trigger_kind: "initial",
      job_kind: "issue",
      step_kind: "grader",
      grader_name: "rspec",
      sample_count: 4,
      attributed_sample_count: 2,
      process_attributed_sample_count: 1,
      host_pressure_sample_count: 4,
      p90_duration_seconds: 300,
      p90_cpu_pressure: 76.5,
      p90_io_pressure: 44.1,
      p90_memory_used_percent: 68.0,
      timeout_rate: 0.0,
      failure_rate: 0.0,
      last_observed_at: now - 1.hour,
      profile_version: WorkflowStepResourceProfile::PROFILE_VERSION
    )
  end

  it "surfaces active and recent top consumers with identity and pressure" do
    _job, workflow, _step, run = workflow_graph
    resource_summary_for(run)
    workflow.update!(artifacts: {
      "workflow_admission_decision" => {
        "pressure" => {
          "candidate" => {
            "predicted_command_cost" => {
              "duration_seconds" => 600,
              "cpu_pressure" => 30.0,
              "io_pressure" => 10.0,
              "memory_used_percent" => 40.0
            }
          }
        }
      }
    })

    payload = described_class.new(now: now).as_json

    expect(payload.dig(:active_consumers, 0)).to include(
      run_id: run.id,
      workflow_id: workflow.id,
      step_kind: "grader",
      grader_name: "rspec",
      repository: repository.slug,
      host: "worker-a",
      wall_time_seconds: 300
    )
    expect(payload.dig(:active_consumers, 0, :pressure)).to include(
      cpu_pressure: 76.5,
      io_pressure: 44.1,
      memory_used_percent: 68.0,
      host_sample_confidence: "sufficient",
      process_attribution_confidence: "high"
    )
    expect(payload.dig(:active_consumers, 0, :estimated_remaining_cost)).to include("duration_seconds" => 600)
    expect(payload.dig(:recent_top_consumers, 0, :run_id)).to eq(run.id)
  end

  it "surfaces delayed admission decisions and resume timing" do
    job = Factories.job_record(user: user, repository: repository, state: "queued", issue_title: "Delayed job")
    workflow = Workflow.create!(job: job, user: user, trigger_kind: "initial", agent_provider: "codex", state: "queued")
    workflow.update!(artifacts: {
      "start_blocked_reason" => StepDispatcher::ADMISSION_BLOCK_REASON,
      "start_blocked_at" => (now - 3.minutes).iso8601,
      "start_blocked_next_check_at" => (now + 7.minutes).iso8601,
      "start_blocked_details" => {
        "action" => "delay_until",
        "reason" => "worker_host_pressure_high",
        "delay_until" => (now + 7.minutes).iso8601,
        "pressure" => {
          "candidate" => {
            "predicted_command_cost" => {
              "duration_seconds" => 900,
              "cpu_pressure" => 80.0
            }
          },
          "host" => { "max_cpu_pressure" => 90.0 }
        },
        "details" => {
          "decision_basis" => "ambient_pressure",
          "fallback_reasons" => [ "insufficient_command_and_host_profile_samples" ]
        }
      }
    })

    delayed = described_class.new(now: now).as_json.fetch(:delayed_work).first

    expect(delayed).to include(
      workflow_id: workflow.id,
      job_id: job.id,
      reason: "worker_host_pressure_high",
      action: "delay_until",
      next_check_at: (now + 7.minutes).iso8601
    )
    expect(delayed.fetch(:estimated_remaining_cost)).to include("duration_seconds" => 900, "cpu_pressure" => 80.0)
    expect(delayed.fetch(:details)).to include("decision_basis" => "ambient_pressure")
  end

  it "surfaces low-confidence profiles and admission override audit entries" do
    profile
    job = Factories.job_record(user: user, repository: repository, state: "running", priority: "urgent")
    workflow = Workflow.create!(job: job, user: user, trigger_kind: "initial", agent_provider: "codex", state: "running")
    workflow.update!(artifacts: {
      "workflow_admission_decided_at" => now.iso8601,
      "workflow_admission_override" => {
        "action" => "admit_now",
        "reason" => "urgent_priority_override",
        "override" => true,
        "pressure" => {
          "candidate" => {
            "predicted_command_cost" => {
              "duration_seconds" => 1200,
              "cpu_pressure" => 95.0
            }
          }
        },
        "details" => { "job_priority" => "urgent" }
      }
    })

    payload = described_class.new(now: now).as_json

    expect(payload.dig(:low_confidence_profiles, 0)).to include(
      repository: repository.slug,
      step_kind: "grader",
      grader_name: "rspec",
      confidence_level: "defaults_only",
      sample_count: 4,
      attributed_sample_count: 2
    )
    expect(payload.dig(:admission_overrides, 0)).to include(
      workflow_id: workflow.id,
      job_id: job.id,
      reason: "urgent_priority_override",
      override: true,
      decided_at: now.iso8601
    )
  end
end
