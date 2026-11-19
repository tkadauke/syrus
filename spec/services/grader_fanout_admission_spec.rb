require "rails_helper"

RSpec.describe GraderFanoutAdmission, :ci_only do
  include ActiveJob::TestHelper

  let(:job) { Factories.job }
  let(:workflow) { job.workflows.last }

  before do
    Feature.find_or_create_by!(slug: "distributed_workflow_dag") do |feature|
      feature.category = "Operations"
      feature.name = "Distributed workflow DAG"
    end.update!(enabled: true)
    Feature.clear_enabled_cache!
    job.repository.update!(distributed_workflow_dag_enabled: true)
  end

  def grader_steps(count)
    count.times.map do |index|
      workflow.steps.create!(
        kind: "grader",
        position: 100 + index,
        placement_policy: Step::PlacementPolicy::IMMUTABLE_SOURCE_CHECKOUT
      )
    end
  end

  it "releases only measured headroom from a large ready grader set" do
    steps = grader_steps(12)
    allow_any_instance_of(described_class).to receive(:healthy_worker_capacity).and_return(3)

    decision = described_class.call(workflow: workflow, steps: steps)

    expect(decision.steps).to eq(steps.first(3))
    expect(decision).to have_attributes(capacity: 3, active_runs: 0, available_slots: 3, reason: "capacity_available")
  end

  it "uses published worker capacity and defers the fanout when that host becomes critical" do
    ensure_solid_queue_test_tables!
    clear_solid_queue_test_tables!
    SolidQueue::Process.create!(
      hostname: "grader-host",
      kind: "worker",
      last_heartbeat_at: Time.current,
      metadata: {
        "queues" => [ "runs" ],
        "capability_diagnostics" => {
          "admission_capacity" => {
            "host_compute_capacity" => 4,
            "grader_capacity_units" => 1,
            "agentic_reserved_units" => 2
          }
        }
      },
      name: "grader-host:1",
      pid: 12_345,
      created_at: Time.current
    )
    steps = grader_steps(5)

    healthy = described_class.call(workflow: workflow, steps: steps)
    WorkerHostHealthSample.create!(
      hostname: "grader-host",
      role: "worker",
      version: "test",
      observed_at: Time.current,
      memory_used_percent: 99
    )
    pressured = described_class.call(workflow: workflow, steps: steps)

    expect(healthy).to have_attributes(capacity: 2, available_slots: 2)
    expect(pressured).to have_attributes(capacity: 0, available_slots: 0, reason: "grader_capacity_saturated")
    expect(pressured.steps).to be_empty
  end

  it "defers every ready grader while existing runnable graders saturate capacity" do
    steps = grader_steps(4)
    steps.first(2).each do |grader|
      grader.runs.create!(job: job, trigger_kind: workflow.trigger_kind, state: "queued")
    end
    allow_any_instance_of(described_class).to receive(:healthy_worker_capacity).and_return(2)

    decision = described_class.call(workflow: workflow, steps: steps.drop(2))

    expect(decision.steps).to be_empty
    expect(decision).to have_attributes(active_runs: 2, available_slots: 0, reason: "grader_capacity_saturated")
  end

  it "releases the next graders in position order when capacity becomes available" do
    steps = grader_steps(5)
    first_run = steps.first.runs.create!(job: job, trigger_kind: workflow.trigger_kind, state: "running")
    allow_any_instance_of(described_class).to receive(:healthy_worker_capacity).and_return(2)

    saturated = described_class.call(workflow: workflow, steps: steps.drop(1))
    first_run.update!(state: "succeeded", finished_at: Time.current)
    resumed = described_class.call(workflow: workflow, steps: steps.drop(1))

    expect(saturated.steps).to eq([ steps.second ])
    expect(resumed.steps).to eq(steps.drop(1).first(2))
  end

  it "serializes headroom observation and reservation across workflows" do
    workflows = [ workflow, Factories.job.workflows.last ]
    contenders = workflows.map.with_index do |candidate, index|
      candidate.steps.create!(kind: "grader", position: 200 + index)
    end
    lock = Mutex.new
    settings = instance_double(AppSetting)
    allow(settings).to receive(:with_lock) { |&block| lock.synchronize(&block) }
    allow(AppSetting).to receive(:current).and_return(settings)
    allow_any_instance_of(described_class).to receive(:healthy_worker_capacity).and_return(1)
    allow_any_instance_of(described_class).to receive(:fair_turn?).and_return(true)

    active = 0
    active_lock = Mutex.new
    allow_any_instance_of(described_class).to receive(:active_grader_runs) do
      active_lock.synchronize { active }
    end

    first_entered = Queue.new
    release_first = Queue.new
    results = Queue.new
    errors = Queue.new
    threads = workflows.zip(contenders).map.with_index do |(candidate, step), index|
      Thread.new do
        described_class.synchronize(workflow: candidate, steps: [ step ]) do |decision|
          if index.zero?
            first_entered << true
            release_first.pop
          end
          active_lock.synchronize { active += decision.steps.size }
          results << decision
        end
      rescue StandardError => e
        errors << e
      end.tap { first_entered.pop if index.zero? }
    end

    # The second workflow has attempted admission but cannot observe the same
    # free slot while the first workflow is still reserving it.
    expect(results).to be_empty
    release_first << true
    threads.each { |thread| thread.join(2) || raise("grader admission thread timed out") }
    raise errors.pop unless errors.empty?

    decisions = 2.times.map { results.pop }
    expect(decisions.sum { |decision| decision.steps.size }).to eq(1)
    expect(decisions.map(&:active_runs)).to contain_exactly(0, 1)
  end

  it "gives an older deferred workflow the next available turn" do
    older_job = Factories.job
    older_workflow = older_job.workflows.last
    older_job.repository.update!(distributed_workflow_dag_enabled: true)
    older_workflow.update!(
      state: "running",
      artifacts: {
        "grader_fanout_admission" => {
          "deferred_at" => 2.minutes.ago.iso8601,
          "ready_count" => 2,
          "released_count" => 1
        }
      }
    )
    older_workflow.steps.create!(
      kind: "grader",
      position: 200,
      placement_policy: Step::PlacementPolicy::IMMUTABLE_SOURCE_CHECKOUT
    )
    candidate = grader_steps(1).first
    allow_any_instance_of(described_class).to receive(:healthy_worker_capacity).and_return(1)

    waiting = described_class.call(workflow: workflow, steps: [ candidate ])
    older_workflow.update!(artifacts: older_workflow.artifacts.deep_merge(
      "grader_fanout_admission" => { "deferred_at" => 1.minute.from_now.iso8601 }
    ))
    admitted = described_class.call(workflow: workflow, steps: [ candidate ])

    expect(waiting).to have_attributes(reason: "waiting_for_fair_turn", steps: [])
    expect(admitted.steps).to eq([ candidate ])
  end

  it "bounds runnable fanout work and reaches collect as completions release slots" do
    workflow.update_columns(state: "running")
    fanout = workflow.steps.create!(kind: "grader_fanout", position: 90, state: "succeeded", finished_at: Time.current)
    steps = grader_steps(6)
    collect = workflow.steps.create!(kind: "grader_collect", position: 106)
    fanout.update!(next_step: steps.first)
    steps.each { |grader| grader.update!(next_step: collect, depends_on_ids: [ fanout.id ]) }
    collect.update!(depends_on_ids: steps.map(&:id))
    allow_any_instance_of(described_class).to receive(:healthy_worker_capacity).and_return(2)

    StepDispatcher.advance_from(fanout, check_phase_admission: false)

    expect(steps.sum { |grader| grader.reload.runs.active.count }).to eq(2)
    expect(workflow.reload.artifact("grader_fanout_admission")).to include(
      "ready_count" => 6,
      "released_count" => 2,
      "capacity" => 2
    )
    expect(enqueued_jobs.count { |entry| entry[:job] == WorkflowPhaseAdmissionJob }).to eq(1)

    steps.each do |grader|
      run = grader.reload.runs.active.last
      next unless run

      run.update_columns(state: "succeeded", finished_at: Time.current)
      grader.update_columns(state: "succeeded", finished_at: Time.current)
      StepDispatcher.advance_from(grader, check_phase_admission: false)
    end
    # The first wave released the second; complete successive waves in the
    # same deterministic order until the fan-in barrier is satisfied.
    until steps.all? { |grader| grader.reload.terminal? }
      grader = steps.find { |candidate| candidate.reload.runs.active.exists? }
      run = grader.runs.active.last
      run.update_columns(state: "succeeded", finished_at: Time.current)
      grader.update_columns(state: "succeeded", finished_at: Time.current)
      StepDispatcher.advance_from(grader, check_phase_admission: false)
    end

    expect(collect.reload.runs.count).to eq(1)
    expect(steps.map { |grader| grader.runs.count }).to all(eq(1))
  end

  it "rechecks a saturated fanout through admission instead of bypassing the bound" do
    workflow.update_columns(state: "running")
    fanout = workflow.steps.create!(kind: "grader_fanout", position: 90, state: "succeeded", finished_at: Time.current)
    steps = grader_steps(3)
    fanout.update!(next_step: steps.first)
    steps.each { |grader| grader.update!(depends_on_ids: [ fanout.id ]) }
    existing = steps.first.runs.create!(job: job, trigger_kind: workflow.trigger_kind, state: "queued")
    allow_any_instance_of(described_class).to receive(:healthy_worker_capacity).and_return(1)

    expect(StepDispatcher.distributed_parallel_grader_candidate?(workflow, steps.second)).to be(true)

    StepDispatcher.resume_deferred_phase(workflow.id, steps.second.id, check_phase_admission: false)

    expect(existing.reload).to be_queued
    expect(steps.sum { |grader| grader.reload.runs.count }).to eq(1)
    expect(workflow.reload.artifact("grader_fanout_admission")).to include(
      "reason" => "grader_capacity_saturated",
      "released_count" => 0
    )
  end
end
