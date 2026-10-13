require "rails_helper"

RSpec.describe SpawnedProcessCgroupBudget do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_record(user: user, repository: repository) }
  let(:workflow) { Workflows::Initial.instantiate(job: job, agent_provider: "codex") }

  before do
    allow(RunProcessParallelism).to receive(:host_capacity).and_return(8)
    allow(RunProcessParallelism).to receive(:effective_memory_limit_bytes).and_return(16 * 1024**3)
  end

  def spawned_process(resources: nil)
    details = { "name" => "rspec" }
    details["resources"] = resources.to_h if resources
    step = Step.create!(workflow: workflow, kind: "grader", position: 99, details: details)
    run = step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, agent_provider: workflow.agent_provider)
    SpawnedProcess.create!(
      run: run,
      workflow: workflow,
      kind: "grader",
      command: "bundle exec rspec",
      hostname: "worker-a",
      started_at: Time.current
    )
  end

  # The declaration and the ceiling the grader runs under have to come from one
  # place; the fair-share estimate must not second-guess a grader that said
  # what it needs.
  it "honors a declared working set instead of the fair-share estimate" do
    process = spawned_process(resources: GraderResourceRequest.new(cpu: 4, memory_bytes: 6 * 1024**3))

    result = described_class.for(spawned_process: process)

    expect(result.memory_max_bytes).to eq(6 * 1024**3)
    expect(result.details["source"]).to eq("declared")
  end

  it "caps a declaration at the pod fraction" do
    process = spawned_process(resources: GraderResourceRequest.new(cpu: 4, memory_bytes: 64 * 1024**3))

    result = described_class.for(spawned_process: process)

    expect(result.memory_max_bytes).to eq((16 * 1024**3 * described_class::DEFAULT_LIMIT_FRACTION).floor)
  end

  it "sets memory.high below memory.max so reclaim starts before the hard kill" do
    process = spawned_process(resources: GraderResourceRequest.new(cpu: 4, memory_bytes: 6 * 1024**3))

    result = described_class.for(spawned_process: process)

    expect(result.memory_high_bytes).to eq((6 * 1024**3 * described_class::DEFAULT_MEMORY_HIGH_FRACTION).floor)
    expect(result.memory_high_bytes).to be < result.memory_max_bytes
  end

  it "falls back to the adaptive estimate when nothing is declared" do
    result = described_class.for(spawned_process: spawned_process)

    expect(result.details["source"]).to eq("adaptive")
    expect(result.memory_max_bytes).to be_positive
  end

  it "ignores a cpu-only declaration for memory purposes" do
    process = spawned_process(resources: GraderResourceRequest.new(cpu: GraderResourceRequest::ALL))

    expect(described_class.for(spawned_process: process).details["source"]).to eq("adaptive")
  end

  it "lets an explicit env override win over a declaration" do
    stub_const("ENV", ENV.to_h.merge("SYRUS_SPAWN_MEMORY_MAX_BYTES" => (2 * 1024**3).to_s))
    process = spawned_process(resources: GraderResourceRequest.new(cpu: 4, memory_bytes: 6 * 1024**3))

    result = described_class.for(spawned_process: process)

    expect(result.memory_max_bytes).to eq(2 * 1024**3)
    expect(result.details["source"]).to eq("env_override")
  end
end
