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
    # effective_memory_limit_bytes takes the MINIMUM of the cgroup v2 limit, the
    # cgroup v1 limit, and /proc/meminfo. Stubbing only the v2 path leaves the
    # other two reading the host, so on a Linux runner whose real memory is
    # below the stubbed 16 GiB the minimum is the host's value and this example
    # fails for a reason that has nothing to do with the code under test. It
    # passed on macOS only because neither fallback path exists there.
    allow(File).to receive(:read).with("/sys/fs/cgroup/memory/memory.limit_in_bytes").and_raise(Errno::ENOENT)
    allow(File).to receive(:read).with("/proc/meminfo").and_raise(Errno::ENOENT)

    expect(described_class.effective_memory_limit_bytes).to eq(16.gigabytes)
    expect(described_class.current_memory_bytes).to eq(2.gigabytes)
  end

  it "does not count active clean file cache as committed process memory" do
    allow(File).to receive(:read).and_call_original
    allow(File).to receive(:read).with("/sys/fs/cgroup/memory.current").and_return("16106127360\n")
    allow(File).to receive(:read).with("/sys/fs/cgroup/memory.stat").and_return(<<~STAT)
      anon 1073741824
      file 13958643712
      file_dirty 268435456
      file_writeback 134217728
      inactive_file 1073741824
    STAT

    expect(described_class.current_memory_bytes).to eq(2.375.gigabytes)
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

  # A container without `limits.cpu` has no cgroup quota, so the probes return
  # nil and `Etc.nprocessors` reports the whole machine. Trusting it is how a
  # worker comes to size parallelism as though it owned the node -- and how two
  # workers sharing a node drove it to 99% CPU, starved their own processes,
  # and had their runs declared dead.
  describe "CPU share when no quota is visible" do
    before do
      described_class.reset_undetectable_cpu_warning!
      allow(described_class).to receive(:cgroup_v2_cpu_count).and_return(nil)
      allow(described_class).to receive(:cgroup_v1_cpu_count).and_return(nil)
      allow(Etc).to receive(:nprocessors).and_return(20)
    end

    after { described_class.reset_undetectable_cpu_warning! }

    it "assumes a small share rather than the host's core count" do
      stub_const("ENV", ENV.to_h.except(described_class::CPU_LIMIT_ENV))

      expect(described_class.effective_cpu_count).to eq(described_class::UNDETECTABLE_CPU_COUNT)
      expect(described_class.effective_cpu_count).to be < 20
    end

    it "honors an explicit core budget so a pod can be sized without a manifest change" do
      stub_const("ENV", ENV.to_h.merge(described_class::CPU_LIMIT_ENV => "8"))

      expect(described_class.effective_cpu_count).to eq(8)
      expect(described_class.host_capacity).to eq(6)
    end

    it "falls back to the small share for a non-numeric budget" do
      stub_const("ENV", ENV.to_h.merge(described_class::CPU_LIMIT_ENV => "lots"))

      expect(described_class.effective_cpu_count).to eq(described_class::UNDETECTABLE_CPU_COUNT)
    end

    it "falls back to the small share for a non-positive budget" do
      stub_const("ENV", ENV.to_h.merge(described_class::CPU_LIMIT_ENV => "0"))

      expect(described_class.effective_cpu_count).to eq(described_class::UNDETECTABLE_CPU_COUNT)
    end

    it "never assumes more than the host actually has" do
      allow(Etc).to receive(:nprocessors).and_return(2)
      stub_const("ENV", ENV.to_h.except(described_class::CPU_LIMIT_ENV))

      expect(described_class.effective_cpu_count).to eq(2)
    end

    it "says so in the log, because a silent wrong number is what caused the outage" do
      stub_const("ENV", ENV.to_h.except(described_class::CPU_LIMIT_ENV))
      allow(Rails.logger).to receive(:warn)

      described_class.effective_cpu_count

      expect(Rails.logger).to have_received(:warn).with(/no CPU quota visible/)
    end
  end

  it "prefers a real cgroup quota over both the override and the assumed share" do
    allow(described_class).to receive(:cgroup_v2_cpu_count).and_return(6)
    stub_const("ENV", ENV.to_h.merge(described_class::CPU_LIMIT_ENV => "99"))

    expect(described_class.effective_cpu_count).to eq(6)
  end
end
