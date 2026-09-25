require "rails_helper"

RSpec.describe RunProcessParallelism do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_record(user: user, repository: repository) }
  let(:workflow) { Workflows::Initial.instantiate(job: job, agent_provider: "codex") }
  let(:step) { Step.create!(workflow: workflow, kind: "grader", position: 99, details: { "name" => "rspec" }) }
  let(:run) { step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, agent_provider: workflow.agent_provider) }

  before do
    allow(described_class).to receive(:host_capacity).and_return(6)
    stub_const("ENV", ENV.to_h.merge("JOB_CONCURRENCY" => "1"))
  end

  it "reserves capacity for simultaneously starting worker threads" do
    stub_const("ENV", ENV.to_h.merge("JOB_CONCURRENCY" => "3"))

    expect(described_class.for(run: run, hostname: "worker-a")).to eq(2)
  end

  it "reserves headroom and caps one grader's process fanout" do
    expect(described_class.for(run: run, hostname: "worker-a")).to eq(6)
  end

  it "divides the CPU budget among active local graders" do
    2.times do
      other_run = step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, agent_provider: workflow.agent_provider)
      SpawnedProcess.create!(
        run: other_run,
        workflow: workflow,
        kind: "grader",
        command: "bundle exec rspec",
        hostname: "worker-a",
        started_at: Time.current
      )
    end

    expect(described_class.for(run: run, hostname: "worker-a")).to eq(2)
  end

  it "does not count completed or remote grader processes" do
    completed_run = step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, agent_provider: workflow.agent_provider)
    SpawnedProcess.create!(
      run: completed_run,
      workflow: workflow,
      kind: "grader",
      command: "bundle exec rspec",
      hostname: "worker-a",
      started_at: 1.minute.ago,
      finished_at: Time.current
    )
    SpawnedProcess.create!(
      run: completed_run,
      workflow: workflow,
      kind: "grader",
      command: "bundle exec rspec",
      hostname: "worker-b",
      started_at: Time.current
    )

    expect(described_class.for(run: run, hostname: "worker-a")).to eq(6)
  end

  it "reads the cgroup v2 memory limit and excludes reclaimable file cache from current usage" do
    allow(File).to receive(:read).and_call_original
    allow(File).to receive(:read).with("/sys/fs/cgroup/memory.max").and_return("17179869184\n")
    allow(File).to receive(:read).with("/sys/fs/cgroup/memory.current").and_return("4294967296\n")
    allow(File).to receive(:read).with("/sys/fs/cgroup/memory.stat").and_return("anon 1073741824\ninactive_file 2147483648\n")

    expect(described_class.effective_memory_limit_bytes).to eq(16.gigabytes)
    expect(described_class.current_memory_bytes).to eq(2.gigabytes)
  end

  it "never reports a negative working set when cache races with usage sampling" do
    allow(File).to receive(:read).and_call_original
    allow(File).to receive(:read).with("/sys/fs/cgroup/memory.current").and_return("1024\n")
    allow(File).to receive(:read).with("/sys/fs/cgroup/memory.stat").and_return("inactive_file 2048\n")

    expect(described_class.current_memory_bytes).to eq(0)
  end

  it "ignores a cgroup v1 unlimited sentinel larger than physical memory" do
    allow(described_class).to receive(:cgroup_v2_memory_limit).and_return(nil)
    allow(described_class).to receive(:cgroup_v1_memory_limit).and_return(8.exabytes)
    allow(described_class).to receive(:proc_memory_total).and_return(16.gigabytes)

    expect(described_class.effective_memory_limit_bytes).to eq(16.gigabytes)
  end
end
