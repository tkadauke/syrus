require "rails_helper"

RSpec.describe PerformanceLogging::MemoryHighWaterSampler do
  let(:first_context) do
    {
      job_class: "PollRepositoryJob",
      active_job_id: "active-1",
      queue_name: "polling",
      repository_id: 12
    }
  end
  let(:second_context) do
    {
      job_class: "WorkEngine::ReconcileJob",
      active_job_id: "active-2",
      queue_name: "control_plane",
      job_id: 34
    }
  end

  before do
    described_class.reset!
    PerformanceLogEvent.delete_all
    allow(described_class).to receive(:start_thread)
    allow(ProcessResourceSampler).to receive(:rss_bytes).and_return(100.megabytes)
    allow(RunProcessParallelism).to receive(:cgroup_memory_current_bytes).and_return(100.megabytes)
    allow(RunProcessParallelism).to receive(:effective_memory_limit_bytes).and_return(1.gigabyte)
    allow(RunProcessParallelism).to receive(:cgroup_memory_events).and_return("oom" => 0, "oom_kill" => 0)
    allow(PerformanceLogging::Store).to receive(:flush!).and_call_original
  end

  after do
    described_class.reset!
    PerformanceLogEvent.delete_all
  end

  it "persists a threshold crossing synchronously and does not repeat its bucket" do
    described_class.register(first_context)
    allow(ProcessResourceSampler).to receive(:rss_bytes).and_return(300.megabytes)

    2.times { described_class.sample! }

    events = PerformanceLogEvent.where(event_name: PerformanceLogging::MEMORY_HIGH_WATER_EVENT)
    expect(events.count).to eq(1)
    expect(events.first.as_event_hash).to include(
      "rss_bytes" => 300.megabytes,
      "cgroup_memory_current_bytes" => 100.megabytes,
      "heap_live_slots" => be_positive
    )
    expect(PerformanceLogging::Store).not_to have_received(:flush!)
  end

  it "includes all active jobs and jobs that joined since the preceding bucket" do
    described_class.register(first_context)
    allow(ProcessResourceSampler).to receive(:rss_bytes).and_return(300.megabytes)
    described_class.sample!
    described_class.register(second_context)
    allow(ProcessResourceSampler).to receive(:rss_bytes).and_return(600.megabytes)

    described_class.sample!

    event = PerformanceLogEvent.where(event_name: PerformanceLogging::MEMORY_HIGH_WATER_EVENT).order(:id).last.as_event_hash
    expect(event["active_jobs"]).to contain_exactly(
      include("job_class" => "PollRepositoryJob", "repository_id" => 12),
      include("job_class" => "WorkEngine::ReconcileJob", "job_id" => 34)
    )
    expect(event["jobs_started_since_previous_bucket"]).to contain_exactly(
      include("job_class" => "WorkEngine::ReconcileJob", "job_id" => 34)
    )
  end

  it "retains a job registered while a crossing sample reads resources for the next bucket" do
    described_class.register(first_context)
    registered_mid_sample = false
    allow(ProcessResourceSampler).to receive(:rss_bytes) do
      unless registered_mid_sample
        registered_mid_sample = true
        described_class.register(second_context)
        300.megabytes
      else
        600.megabytes
      end
    end

    described_class.sample!
    described_class.sample!

    events = PerformanceLogEvent.where(event_name: PerformanceLogging::MEMORY_HIGH_WATER_EVENT).order(:id).map(&:as_event_hash)
    expect(events.last["jobs_started_since_previous_bucket"]).to contain_exactly(
      include("job_class" => "WorkEngine::ReconcileJob", "job_id" => 34)
    )
  end

  it "is inert without active jobs and samples resources once regardless of job count" do
    described_class.sample!
    expect(ProcessResourceSampler).not_to have_received(:rss_bytes)

    described_class.register(first_context)
    described_class.register(second_context)
    described_class.sample!

    expect(ProcessResourceSampler).to have_received(:rss_bytes).once
    expect(RunProcessParallelism).to have_received(:cgroup_memory_current_bytes).once
    expect(described_class::SAMPLE_INTERVAL).to eq(1.0)
  end

  it "uses one process-wide sampler thread for concurrent jobs" do
    thread = instance_double(Thread, alive?: true, kill: nil)
    allow(Thread).to receive(:new).and_return(thread)
    allow(described_class).to receive(:start_thread).and_call_original

    described_class.register(first_context)
    described_class.register(second_context)

    expect(Thread).to have_received(:new).once
  end

  it "lets a registration replace a sampler that atomically retires while idle" do
    retiring_thread = instance_double(Thread, alive?: true, kill: nil)
    replacement_thread = instance_double(Thread, alive?: true, kill: nil)
    allow(Thread).to receive(:new).and_return(retiring_thread, replacement_thread)
    allow(described_class).to receive(:start_thread).and_call_original
    token = described_class.register(first_context)
    described_class.unregister(token)

    expect(described_class.send(:retire_thread_if_idle, retiring_thread)).to be(true)
    described_class.register(second_context)

    expect(Thread).to have_received(:new).twice
  end

  it "swallows sampling and persistence failures instead of raising into observed work" do
    token = described_class.register(first_context)
    allow(ProcessResourceSampler).to receive(:rss_bytes).and_raise(Errno::EIO)
    expect { described_class.sample! }.not_to raise_error

    allow(ProcessResourceSampler).to receive(:rss_bytes).and_return(300.megabytes)
    allow(PerformanceLogEvent).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, "unavailable")
    expect { described_class.sample! }.not_to raise_error
    expect { described_class.unregister(token) }.not_to raise_error
  end

  it "persists a normal-completion summary with job start, end, and peaks" do
    token = described_class.register(first_context)
    allow(ProcessResourceSampler).to receive(:rss_bytes).and_return(300.megabytes)
    described_class.sample!

    described_class.unregister(token)

    event = PerformanceLogEvent.find_by!(event_name: PerformanceLogging::JOB_MEMORY_SUMMARY_EVENT).as_event_hash
    expect(event).to include(
      "job_class" => "PollRepositoryJob",
      "queue_name" => "polling",
      "start_rss_bytes" => 300.megabytes,
      "end_rss_bytes" => 300.megabytes,
      "peak_rss_bytes" => 300.megabytes,
      "started_at" => be_present,
      "ended_at" => be_present
    )
  end
end
