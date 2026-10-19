require "rails_helper"

RSpec.describe DistributedRunAdmissionRouter do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_record(user: user, repository: repository, state: "running") }
  let(:workflow) { Workflow.create!(job: job, trigger_kind: "initial", state: "running") }
  let(:step) do
    Step.create!(
      workflow: workflow,
      kind: "grader",
      position: 10,
      placement_policy: Step::PlacementPolicy::IMMUTABLE_SOURCE_CHECKOUT,
      details: { "name" => "rspec", "required_capabilities" => { "os" => [ "linux" ] } }
    )
  end
  let(:run) { step.runs.create!(job: job, trigger_kind: workflow.trigger_kind) }
  let(:admission) do
    RunHostAdmission::Decision.new(
      action: "defer", reason: "local_worker_pressure_critical", delay: 30.seconds,
      details: { "hostname" => "worker-a" }
    )
  end

  before do
    Feature.find_or_create_by!(slug: "distributed_workflow_dag") do |feature|
      feature.category = "Operations"
      feature.name = "Distributed workflow DAG"
    end.update!(enabled: true)
    repository.update!(distributed_workflow_dag_enabled: true)
    allow(RunProcessParallelism).to receive(:host_capacity).and_return(4)
  end

  def worker(hostname, storage_key, eligible: true)
    {
      "hostname" => hostname,
      "worker_storage_key" => storage_key,
      "queues" => [ "runs", "resume-#{storage_key}" ],
      "eligible" => eligible
    }
  end

  def sample(hostname, **attributes)
    WorkerHostHealthSample.create!({
      hostname: hostname, role: "worker", version: "test", observed_at: Time.current,
      cpu_used_percent: 5, memory_used_percent: 10, data_root_used_percent: 10,
      raw_metrics: {}
    }.merge(attributes))
  end

  def resolver_with(*workers)
    decision = RunQueueResolver::Decision.new(
      queue_name: "runs", requirements: { "os" => [ "linux" ] }, sticky_resume: false,
      blocked_reason: nil, details: { "live_workers" => workers }
    )
    allow(RunQueueResolver).to receive(:resolve).with(run: run).and_return(decision)
  end

  it "routes promptly to a healthy compatible worker and excludes the rejecting host" do
    resolver_with(worker("worker-a", "storage-a"), worker("worker-b", "storage-b"))
    sample("worker-a", cpu_pressure_some: 55, cpu_pressure_full: 6)
    sample("worker-b")

    decision = described_class.call(run: run, admission: admission)

    expect(decision).to be_reroute
    expect(decision.queue_name).to eq("resume-storage-b")
    expect(decision.delay).to be_nil
    expect(decision.details).to include(
      "rejecting_worker" => "worker-a",
      "routed_worker" => "worker-b",
      "routing_decision" => "healthy_alternative"
    )
  end

  it "filters out workers that do not satisfy the Run's capabilities" do
    resolver_with(worker("worker-a", "storage-a"), worker("worker-b", "storage-b", eligible: false))
    sample("worker-a", cpu_pressure_some: 55, cpu_pressure_full: 6)
    sample("worker-b")

    decision = described_class.call(run: run, admission: admission)

    expect(decision).not_to be_reroute
    expect(decision.details.fetch("healthy_alternatives_considered").map { |entry| entry["hostname"] }).to eq([ "worker-a" ])
  end

  it "backs off and resets bounded exclusions when every eligible worker is pressured" do
    workflow.update!(artifacts: {
      "run_host_admission" => {
        "run_id" => run.id, "deferral_count" => 2, "excluded_workers" => [ "worker-b" ]
      }
    })
    resolver_with(worker("worker-a", "storage-a"), worker("worker-b", "storage-b"))
    sample("worker-a", cpu_pressure_some: 55, cpu_pressure_full: 6)
    sample("worker-b", memory_used_percent: 96)

    decision = described_class.call(run: run, admission: admission)

    expect(decision.action).to eq("defer")
    expect(decision.delay).to eq(2.minutes)
    expect(decision.details).to include(
      "routing_decision" => "all_eligible_workers_pressured",
      "excluded_workers" => [],
      "completed_exclusion_cycle" => contain_exactly("worker-a", "worker-b")
    )
  end
end
