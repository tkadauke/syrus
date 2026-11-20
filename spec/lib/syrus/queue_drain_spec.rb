require "rails_helper"

RSpec.describe Syrus::QueueDrain do
  def worker_process(metadata = { "queues" => "worker-compute-a,runs" })
    ensure_solid_queue_test_tables!
    SolidQueue::Process.create!(
      hostname: "compute-a", kind: "Worker", name: "worker-#{SecureRandom.hex(3)}", pid: 123,
      last_heartbeat_at: Time.current, metadata: metadata
    )
  end

  it "stamps the process as draining without losing its advertised queues" do
    process = worker_process

    described_class.mark!(process, now: Time.utc(2026, 11, 19, 23, 30))

    reloaded = SolidQueue::Process.find(process.id)
    expect(described_class.draining?(reloaded)).to eq(true)
    expect(reloaded.metadata["queues"]).to eq("worker-compute-a,runs")
    expect(reloaded.metadata["draining_since"]).to eq("2026-11-19T23:30:00Z")
  end

  it "survives a later heartbeat" do
    process = worker_process
    described_class.mark!(process)

    process.heartbeat

    expect(described_class.draining?(SolidQueue::Process.find(process.id))).to eq(true)
  end

  it "never raises out of a worker shutdown" do
    process = worker_process
    allow(process).to receive(:update_columns).and_raise(ActiveRecord::ConnectionNotEstablished)

    expect { described_class.mark!(process) }.not_to raise_error
  end

  it "is registered as a SolidQueue worker stop hook" do
    process = worker_process
    worker = instance_double(SolidQueue::Worker, process_id: process.id)

    SolidQueue::Worker.lifecycle_hooks[:stop].each { |hook| hook.call(worker) }

    expect(described_class.draining?(SolidQueue::Process.find(process.id))).to eq(true)
  end

  it "makes a draining worker's queues stop counting as live" do
    process = worker_process
    expect(InstanceVersion.worker_queue_live?("worker-compute-a")).to eq(true)

    described_class.mark!(process)

    expect(InstanceVersion.worker_queue_live?("worker-compute-a")).to eq(false)
  end

  it "keeps a shared queue live while another worker still serves it" do
    draining = worker_process("queues" => "resume-node-a,runs")
    worker_process("queues" => "resume-node-a,runs")

    described_class.mark!(draining)

    expect(InstanceVersion.worker_queue_live?("resume-node-a")).to eq(true)
  end
end
