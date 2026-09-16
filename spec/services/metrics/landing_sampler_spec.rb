require "rails_helper"

# Job/Run/Step are ordinary ActiveRecord tables (unlike solid_queue_*, see
# CLAUDE.md), so Metrics::LandingSource is exercised directly with real
# records here rather than through a fake -- only the Solid Queue-backed half
# (Metrics::QueueSource#table_rows/#completed_count) needs a stand-in.
RSpec.describe Metrics::LandingSampler do
  class FakeLandingQueueSource
    attr_writer :table_rows, :completed_count_value

    def initialize
      @table_rows = 0
      @completed_count_value = 0
    end

    def table_rows = resolve(@table_rows)
    def completed_count(after:, through:) = resolve(@completed_count_value)

    private

    def resolve(value)
      raise value if value.is_a?(Exception)

      value
    end
  end

  # A stand-in for Metrics::LandingSource, used only to exercise the
  # per-source degradation guard -- real Job/Run rows cannot be made to raise.
  class FakeLandingSource
    attr_writer :job_state_counts, :landing_queue_blocked_reason_counts, :finished_runs, :landed_jobs

    def initialize
      @job_state_counts = {}
      @landing_queue_blocked_reason_counts = {}
      @finished_runs = []
      @landed_jobs = []
    end

    def job_state_counts = resolve(@job_state_counts)
    def landing_queue_blocked_reason_counts = resolve(@landing_queue_blocked_reason_counts)
    def finished_runs(after:, through:) = resolve(@finished_runs)
    def landed_jobs(after:, through:) = resolve(@landed_jobs)

    private

    def resolve(value)
      raise value if value.is_a?(Exception)

      value
    end
  end

  let(:cache) { ActiveSupport::Cache::MemoryStore.new }
  let(:queue_source) { FakeLandingQueueSource.new }

  around do |example|
    original = Syrus::Metrics.registry
    Syrus::Metrics.reset!
    described_class.declare_metrics!
    example.run
  ensure
    Syrus::Metrics.instance_variable_set(:@registry, original)
  end

  before { allow(Rails).to receive(:cache).and_return(cache) }

  def sample!(source: nil)
    described_class.sample!(**{ queue_source: queue_source }.merge(source ? { source: source } : {}))
  end

  describe "#sample!" do
    it "bootstraps the cursor on the first tick without instrumenting existing history" do
      t0 = Time.current
      travel_to(t0 - 1.hour) do
        job_with_run(
          run_attrs: { state: "succeeded", trigger_kind: "initial", started_at: Time.current - 5, finished_at: Time.current }
        )
      end

      travel_to(t0) { sample! }

      expect(Syrus::Metrics.render).not_to include("syrus_runs_total{")
    end

    it "instruments a Run that finishes after the first tick into runs_total and run_duration_seconds" do
      t0 = Time.current
      travel_to(t0) { sample! } # bootstrap

      travel_to(t0 + 1.minute) do
        job_with_run(
          run_attrs: { state: "succeeded", trigger_kind: "initial", started_at: Time.current - 30, finished_at: Time.current },
          step_attrs: { kind: "implement" }
        )
      end

      travel_to(t0 + 2.minutes) { sample! }

      rendered = Syrus::Metrics.render
      expect(rendered).to include('syrus_runs_total{state="succeeded",trigger_kind="initial"} 1')
      expect(rendered).to include('syrus_run_duration_seconds_bucket{step_kind="implement",le="60"} 1')
      expect(rendered).to include('syrus_run_duration_seconds_count{step_kind="implement"} 1')
    end

    it "does not double-count a Run already instrumented on a prior tick" do
      t0 = Time.current
      travel_to(t0) { sample! }
      travel_to(t0 + 1.minute) do
        job_with_run(run_attrs: { state: "failed", trigger_kind: "pr_comment", started_at: Time.current - 10, finished_at: Time.current })
      end
      travel_to(t0 + 2.minutes) { sample! }
      travel_to(t0 + 3.minutes) { sample! }

      expect(Syrus::Metrics.render).to include('syrus_runs_total{state="failed",trigger_kind="pr_comment"} 1')
    end

    it "counts a Run with no Step toward runs_total without a duration observation" do
      t0 = Time.current
      travel_to(t0) { sample! }

      job = nil
      travel_to(t0 + 1.minute) do
        job = job_with_run(run_attrs: { state: "cancelled", trigger_kind: "initial", started_at: Time.current - 1, finished_at: Time.current })
      end
      job.current_run.update_columns(step_id: nil)

      travel_to(t0 + 2.minutes) { sample! }

      rendered = Syrus::Metrics.render
      expect(rendered).to include('syrus_runs_total{state="cancelled",trigger_kind="initial"} 1')
      expect(rendered).not_to include("syrus_run_duration_seconds_count{")
    end

    it "instruments a landed Job into jobs_landed_total and time_to_land_seconds" do
      t0 = Time.current
      travel_to(t0) { sample! }

      travel_to(t0 + 1.minute) do
        job_record(state: "closed", closure_reason: "pr_merged", created_at: Time.current - 3600, finished_at: Time.current)
      end

      travel_to(t0 + 2.minutes) { sample! }

      rendered = Syrus::Metrics.render
      expect(rendered).to include("syrus_jobs_landed_total 1")
      expect(rendered).to include('syrus_time_to_land_seconds_bucket{le="3600"} 1')
    end

    it "does not count a closed Job that did not land" do
      t0 = Time.current
      travel_to(t0) { sample! }

      travel_to(t0 + 1.minute) do
        job_record(state: "closed", closure_reason: "no_changes", finished_at: Time.current)
      end

      travel_to(t0 + 2.minutes) { sample! }

      expect(Syrus::Metrics.render).not_to include("syrus_jobs_landed_total")
    end

    it "instruments completed Solid Queue executions into queue_completed_total" do
      t0 = Time.current
      travel_to(t0) { sample! } # bootstrap

      queue_source.completed_count_value = 7
      travel_to(t0 + 1.minute) { sample! }

      expect(Syrus::Metrics.render).to include("syrus_queue_completed_total 7")
    end

    it "caches job_state, landing_queue_depth and queue_table_rows for the scrape path" do
      job_record(state: "approved")
      job_record(state: "running")
      queue_source.table_rows = 12_345

      sample!

      expect(described_class.refresh_gauges!(queue_source: queue_source)).to be(true)
      rendered = Syrus::Metrics.render
      expect(rendered).to include('syrus_job_state{state="approved"} 1')
      expect(rendered).to include('syrus_job_state{state="running"} 1')
      expect(rendered).to include("syrus_queue_table_rows 12345")
    end

    it "groups the landing queue by the blocked reason's bounded key, not its params" do
      job = job_record(state: "approved")
      job.update_columns(landing_queue_blocked_reason: { "key" => "waiting_github_mergeability", "params" => { "slug" => "JOB-1" } })
      eligible = job_record(state: "approved")
      eligible.update_columns(landing_queue_blocked_reason: nil)

      sample!
      described_class.refresh_gauges!(queue_source: queue_source)

      rendered = Syrus::Metrics.render
      expect(rendered).to include('syrus_landing_queue_depth{blocked_reason="waiting_github_mergeability"} 1')
      expect(rendered).to include('syrus_landing_queue_depth{blocked_reason="none"} 1')
      expect(rendered).not_to include("JOB-1")
    end

    # One unreachable source costs its own metrics, not the whole tick --
    # same degradation posture as Metrics::QueueSampler.
    it "degrades one failing source without losing the rest of the sample" do
      source = FakeLandingSource.new
      source.job_state_counts = ActiveRecord::StatementInvalid.new("no such table")
      queue_source.table_rows = 99

      expect { sample!(source: source) }.not_to raise_error
      described_class.refresh_gauges!(queue_source: queue_source)

      expect(Syrus::Metrics.render).to include("syrus_queue_table_rows 99")
    end
  end

  describe "#refresh_gauges!" do
    it "reports nothing rather than zeroes when no sample has been taken" do
      expect(described_class.refresh_gauges!(queue_source: queue_source)).to be(false)
      expect(Syrus::Metrics.render).not_to include("syrus_job_state{")
    end
  end
end
