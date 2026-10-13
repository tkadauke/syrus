require "rails_helper"

RSpec.describe GraderResourceGrant do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_record(user: user, repository: repository) }
  let(:workflow) { Workflows::Initial.instantiate(job: job, agent_provider: "codex") }
  let(:unbounded) { GraderResourceRequest.new(cpu: GraderResourceRequest::ALL, cpu_min: 2) }

  before do
    described_class.reset_inflight!
    allow(RunProcessParallelism).to receive(:host_capacity).and_return(8)
    allow(RunProcessParallelism).to receive(:effective_memory_limit_bytes).and_return(16 * 1024**3)
  end

  after { described_class.reset_inflight! }

  def grader_step(resources: nil, position: 99)
    details = { "name" => "rspec" }
    details["resources"] = resources.to_h if resources
    Step.create!(workflow: workflow, kind: "grader", position: position, details: details)
  end

  def run_for(step)
    step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, agent_provider: workflow.agent_provider)
  end

  def spawn_for(run, hostname: "worker-a")
    SpawnedProcess.create!(
      run: run,
      workflow: workflow,
      kind: "grader",
      command: "bundle exec rspec",
      hostname: hostname,
      started_at: Time.current
    )
  end

  describe "cpu resolution" do
    # The regression this whole change exists for: the old
    # RunProcessParallelism divisor handed a lone rspec grader
    # host_capacity / max(concurrent, JOB_CONCURRENCY=3) -- 2 cores out of 8 --
    # whether or not any other grader was running.
    it "grants an unbounded grader the whole host when nothing else is claiming it" do
      run = run_for(grader_step(resources: unbounded))

      grant = described_class.for(run: run, hostname: "worker-a")

      expect(grant.cpu_cores).to eq(8)
    end

    it "ignores JOB_CONCURRENCY entirely" do
      stub_const("ENV", ENV.to_h.merge("JOB_CONCURRENCY" => "6"))
      run = run_for(grader_step(resources: unbounded))

      expect(described_class.for(run: run, hostname: "worker-a").cpu_cores).to eq(8)
    end

    it "subtracts a concurrent grader's declared claim rather than counting slots" do
      peer = run_for(grader_step(resources: GraderResourceRequest.new(cpu: 3), position: 98))
      spawn_for(peer)
      run = run_for(grader_step(resources: unbounded))

      expect(described_class.for(run: run, hostname: "worker-a").cpu_cores).to eq(5)
    end

    it "charges an undeclared concurrent grader a single core" do
      3.times { |i| spawn_for(run_for(grader_step(position: 90 + i))) }
      run = run_for(grader_step(resources: unbounded))

      expect(described_class.for(run: run, hostname: "worker-a").cpu_cores).to eq(5)
    end

    it "splits the remainder between two unbounded graders instead of overcommitting" do
      spawn_for(run_for(grader_step(resources: unbounded, position: 98)))
      run = run_for(grader_step(resources: unbounded))

      expect(described_class.for(run: run, hostname: "worker-a").cpu_cores).to eq(4)
    end

    it "honors a bounded request below the available remainder" do
      run = run_for(grader_step(resources: GraderResourceRequest.new(cpu: 3)))

      expect(described_class.for(run: run, hostname: "worker-a").cpu_cores).to eq(3)
    end

    it "leaves a core for each unbounded peer when granting a bounded request" do
      spawn_for(run_for(grader_step(resources: unbounded, position: 98)))
      run = run_for(grader_step(resources: GraderResourceRequest.new(cpu: 8)))

      expect(described_class.for(run: run, hostname: "worker-a").cpu_cores).to eq(7)
    end

    it "never grants less than one core however crowded the host is" do
      12.times { |i| spawn_for(run_for(grader_step(resources: GraderResourceRequest.new(cpu: 4), position: 60 + i))) }
      run = run_for(grader_step(resources: unbounded))

      expect(described_class.for(run: run, hostname: "worker-a").cpu_cores).to eq(1)
    end

    it "never grants more than the host has" do
      run = run_for(grader_step(resources: GraderResourceRequest.new(cpu: 64)))

      expect(described_class.for(run: run, hostname: "worker-a").cpu_cores).to eq(8)
    end

    it "ignores graders claiming a different host" do
      spawn_for(run_for(grader_step(resources: GraderResourceRequest.new(cpu: 6), position: 98)), hostname: "worker-b")
      run = run_for(grader_step(resources: unbounded))

      expect(described_class.for(run: run, hostname: "worker-a").cpu_cores).to eq(8)
    end

    it "reads the request from Step#details when none is passed" do
      run = run_for(grader_step(resources: GraderResourceRequest.new(cpu: 2)))

      expect(described_class.for(run: run, hostname: "worker-a").cpu_cores).to eq(2)
    end
  end

  describe "the in-process startup race" do
    # Several grader Runs can be claimed by one threaded Solid Queue worker
    # before any registers a SpawnedProcess. Without the in-flight registry
    # each would see an idle host and claim all of it.
    it "counts a grant already handed out in this process but not yet spawned" do
      first = run_for(grader_step(resources: unbounded, position: 98))
      first.update!(state: "running")
      expect(described_class.for(run: first, hostname: "worker-a").cpu_cores).to eq(8)

      second = run_for(grader_step(resources: unbounded))

      expect(described_class.for(run: second, hostname: "worker-a").cpu_cores).to eq(1)
    end

    # A Run can still be queued when its grader builds its environment, which
    # is exactly the window the registry exists to cover.
    it "counts a claim held by a still-queued Run" do
      first = run_for(grader_step(resources: GraderResourceRequest.new(cpu: 3), position: 98))
      expect(first.state).to eq("queued")
      described_class.for(run: first, hostname: "worker-a")

      second = run_for(grader_step(resources: unbounded))

      expect(described_class.for(run: second, hostname: "worker-a").cpu_cores).to eq(5)
    end

    it "drops an in-flight claim once its Run reaches a terminal state" do
      first = run_for(grader_step(resources: unbounded, position: 98))
      first.update!(state: "running")
      described_class.for(run: first, hostname: "worker-a")
      first.update!(state: "succeeded")

      second = run_for(grader_step(resources: unbounded))

      expect(described_class.for(run: second, hostname: "worker-a").cpu_cores).to eq(8)
    end

    it "does not charge a peer twice once its in-flight claim has become a spawn" do
      peer_step = grader_step(resources: GraderResourceRequest.new(cpu: 3), position: 98)
      peer = run_for(peer_step)
      peer.update!(state: "running")
      described_class.for(run: peer, hostname: "worker-a")
      spawn_for(peer)

      run = run_for(grader_step(resources: unbounded))

      # 8 - 3, not 8 - 3 - 3.
      expect(described_class.for(run: run, hostname: "worker-a").cpu_cores).to eq(5)
    end

    it "releases a claim explicitly" do
      first = run_for(grader_step(resources: unbounded, position: 98))
      first.update!(state: "running")
      described_class.for(run: first, hostname: "worker-a")
      described_class.release_inflight!(first.id)

      second = run_for(grader_step(resources: unbounded))

      expect(described_class.for(run: second, hostname: "worker-a").cpu_cores).to eq(8)
    end
  end

  describe "memory resolution" do
    it "grants nothing when no memory is declared, leaving the adaptive budget in charge" do
      run = run_for(grader_step(resources: unbounded))

      expect(described_class.for(run: run, hostname: "worker-a").memory_max_bytes).to be_nil
    end

    it "grants a declared working set" do
      run = run_for(grader_step(resources: GraderResourceRequest.new(cpu: 2, memory_bytes: 4 * 1024**3)))

      expect(described_class.for(run: run, hostname: "worker-a").memory_max_bytes).to eq(4 * 1024**3)
    end

    it "caps a declaration that asks for more of the pod than the budget would ever allow" do
      run = run_for(grader_step(resources: GraderResourceRequest.new(cpu: 2, memory_bytes: 32 * 1024**3)))

      expect(described_class.for(run: run, hostname: "worker-a").memory_max_bytes)
        .to eq((16 * 1024**3 * described_class::MEMORY_LIMIT_FRACTION).floor)
    end
  end

  describe "details" do
    it "records both sides of the resolution so a bad grant is diagnosable" do
      run = run_for(grader_step(resources: unbounded))

      details = described_class.for(run: run, hostname: "worker-a").details

      expect(details).to include(
        "host_capacity" => 8,
        "requested_cpu" => GraderResourceRequest::ALL,
        "granted_cpu_cores" => 8,
        "fixed_claims" => 0,
        "unbounded_claimants" => 0
      )
    end

    it "flags a grant that fell below the declared useful minimum" do
      12.times { |i| spawn_for(run_for(grader_step(resources: GraderResourceRequest.new(cpu: 4), position: 60 + i))) }
      run = run_for(grader_step(resources: unbounded))

      expect(described_class.for(run: run, hostname: "worker-a").details["below_cpu_min"]).to be(true)
    end
  end
end
