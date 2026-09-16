require "rails_helper"

# AutoRetryAttempt and ProviderSession are ordinary ActiveRecord tables
# (unlike solid_queue_*, see CLAUDE.md), so Metrics::MaintenanceSource is
# exercised directly with real records here. Metrics::QueueSource's
# recurring-job reading is Solid Queue-backed, so it is exercised through a
# fake -- the same split Metrics::LandingSampler's own spec uses between
# Metrics::LandingSource and Metrics::QueueSource.
RSpec.describe Metrics::MaintenanceSampler do
  class FakeMaintenanceQueueSource
    attr_writer :recurring_job_last_success

    def initialize
      @recurring_job_last_success = {}
    end

    def recurring_job_last_success_at = resolve(@recurring_job_last_success)

    private

    def resolve(value)
      raise value if value.is_a?(Exception)

      value
    end
  end

  # A stand-in for Metrics::MaintenanceSource, used only to exercise the
  # per-source degradation guard -- real AutoRetryAttempt/ProviderSession rows
  # cannot be made to raise.
  class FakeMaintenanceSource
    attr_writer :provider_sessions_bytes, :provider_sessions_rows, :settled_auto_retry_attempts

    def initialize
      @provider_sessions_bytes = 0
      @provider_sessions_rows = 0
      @settled_auto_retry_attempts = []
    end

    def provider_sessions_bytes = resolve(@provider_sessions_bytes)
    def provider_sessions_rows = resolve(@provider_sessions_rows)
    def settled_auto_retry_attempts(after:, through:) = resolve(@settled_auto_retry_attempts)

    private

    def resolve(value)
      raise value if value.is_a?(Exception)

      value
    end
  end

  let(:cache) { ActiveSupport::Cache::MemoryStore.new }
  let(:queue_source) { FakeMaintenanceQueueSource.new }

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

  def refresh!
    described_class.refresh_gauges!(queue_source: queue_source)
  end

  # Metrics::MaintenanceSource#settled_auto_retry_attempts only reads
  # AutoRetryAttempt rows directly, but building the Job/Workflow/Run graph
  # they belong to with `Factories.job` routes through the full WorkUnits
  # launcher/admission path, which references `syrus_admission_decisions_total`
  # -- a metric this spec's registry reset (see `around` above) has wiped.
  # `job_with_run` builds the minimal graph without that launcher, the same
  # seam Metrics::ResilienceSampler's and Metrics::LandingSampler's own specs
  # use for exactly this reason.
  def create_attempt(**overrides)
    job = Factories.job_with_run
    workflow = job.latest_workflow
    AutoRetryAttempt.create!({
      job: job,
      workflow: workflow,
      run: job.runs.first,
      agent_provider: "claude",
      failure_classification: "worker_died",
      retry_kind: "failed_step",
      attempt_number: 1,
      scheduled_at: 5.minutes.from_now
    }.merge(overrides))
  end

  describe "#sample!" do
    it "reports how long ago a recurring job last succeeded" do
      # travel_to truncates the mocked "now" to whole seconds, but a bare
      # Time.current keeps sub-second precision -- floor it first so `at` and
      # the frozen `now` disagree by exactly 0, not by a random sub-second
      # fraction that occasionally rounds the elapsed seconds down by one.
      t0 = Time.current.floor
      queue_source.recurring_job_last_success = { "prune_provider_sessions" => t0 - 600 }

      travel_to(t0) do
        sample!
        refresh!
      end

      expect(Syrus::Metrics.render).to include('syrus_recurring_job_last_success_seconds{job="prune_provider_sessions"} 600')
    end

    it "omits a job with no recorded success yet rather than reporting zero" do
      sample!
      refresh!

      expect(Syrus::Metrics.render).not_to include("syrus_recurring_job_last_success_seconds{")
    end

    # The whole point of this gauge: Solid Queue prunes finished job rows
    # after SolidQueue.clear_finished_jobs_after (1 day by default), far
    # short of the staleness this metric exists to catch. A tick where the
    # source stops reporting a job (because its last successful row finally
    # aged out of solid_queue_jobs) must not make that job look unobserved --
    # it must keep growing the age from the last real observation.
    it "keeps growing the last-known age after Solid Queue prunes the evidence, instead of losing it" do
      t0 = Time.current
      queue_source.recurring_job_last_success = { "prune_provider_sessions" => t0 - 1.hour }
      travel_to(t0) { sample! }

      t1 = t0 + 2.days
      queue_source.recurring_job_last_success = {} # the successful row has since been pruned
      travel_to(t1) do
        sample!
        refresh!
      end

      expected_age = (t1 - (t0 - 1.hour)).round
      expect(Syrus::Metrics.render).to include(%(syrus_recurring_job_last_success_seconds{job="prune_provider_sessions"} #{expected_age}))
    end

    it "never lets a job's last-success timestamp regress" do
      t0 = Time.current
      queue_source.recurring_job_last_success = { "prune_provider_sessions" => t0 - 10.minutes }
      travel_to(t0) { sample! }

      # A later tick observing a stale-looking read (e.g. a replica lag
      # artifact) must not roll the high-water mark backwards.
      t1 = t0 + 5.minutes
      queue_source.recurring_job_last_success = { "prune_provider_sessions" => t0 - 9.hours }
      travel_to(t1) do
        sample!
        refresh!
      end

      expect(Syrus::Metrics.render).to include('syrus_recurring_job_last_success_seconds{job="prune_provider_sessions"} 900')
    end

    it "caches provider_sessions_bytes and provider_sessions_rows" do
      run1 = Factories.job_with_run.runs.first
      run2 = Factories.job_with_run.runs.first
      ProviderSession.create!(resumable: run1, session_id: "s1", transcript_jsonl: "x" * 100)
      ProviderSession.create!(resumable: run2, session_id: "s2", transcript_jsonl: "x" * 50)

      sample!
      refresh!

      rendered = Syrus::Metrics.render
      expect(rendered).to include("syrus_provider_sessions_bytes 150")
      expect(rendered).to include("syrus_provider_sessions_rows 2")
    end

    it "bootstraps the auto-retry cursor on the first tick without instrumenting existing history" do
      t0 = Time.current
      travel_to(t0 - 1.hour) { create_attempt(performed_at: Time.current) }

      travel_to(t0) { sample! }
      refresh!

      expect(Syrus::Metrics.render).not_to include("syrus_auto_retry_attempts_total{")
    end

    it "instruments a performed attempt as skip_reason=none" do
      t0 = Time.current
      travel_to(t0) { sample! } # bootstrap

      travel_to(t0 + 1.minute) { create_attempt(performed_at: Time.current) }

      travel_to(t0 + 2.minutes) { sample! }
      refresh!

      expect(Syrus::Metrics.render).to include('syrus_auto_retry_attempts_total{skip_reason="none"} 1')
    end

    it "categorizes a skipped attempt's reason into its bounded category, not the raw interpolated string" do
      t0 = Time.current
      travel_to(t0) { sample! } # bootstrap

      travel_to(t0 + 1.minute) {
        create_attempt(skipped_reason: "failure classification changed from turn_failed to worker_died before retry")
      }

      travel_to(t0 + 2.minutes) { sample! }
      refresh!

      rendered = Syrus::Metrics.render
      expect(rendered).to include('syrus_auto_retry_attempts_total{skip_reason="failure_classification_changed"} 1')
      expect(rendered).not_to include("turn_failed")
    end

    # The regression class this counter exists to guard against: a permanent
    # skip condition wrongly treated as budget-exempt produced ~460,000
    # attempts at two per second (see CLAUDE.md "Failure resilience"). A rate
    # panel on this counter, split by category, is the direct instrument --
    # this asserts the not-retryable path is counted into its own distinct
    # category rather than folding into a budget-exempt bucket.
    it "counts a not-retryable skip separately from the budget-exempt categories" do
      t0 = Time.current
      travel_to(t0) { sample! } # bootstrap

      travel_to(t0 + 1.minute) {
        create_attempt(skipped_reason: "#{AutoRetryAttempt::NOT_RETRYABLE_SKIP_PREFIX}: worker_died_under_resource_pressure")
      }

      travel_to(t0 + 2.minutes) { sample! }
      refresh!

      expect(Syrus::Metrics.render).to include('syrus_auto_retry_attempts_total{skip_reason="not_retryable"} 1')
    end

    it "does not double-count an attempt already instrumented on a prior tick" do
      t0 = Time.current
      travel_to(t0) { sample! }
      travel_to(t0 + 1.minute) { create_attempt(performed_at: Time.current) }
      travel_to(t0 + 2.minutes) { sample! }
      travel_to(t0 + 3.minutes) { sample! }

      refresh!
      refresh!

      expect(Syrus::Metrics.render).to include('syrus_auto_retry_attempts_total{skip_reason="none"} 1')
    end

    it "accumulates across ticks so a single refresh reflects the full total" do
      t0 = Time.current
      travel_to(t0) { sample! }

      travel_to(t0 + 1.minute) { create_attempt(performed_at: Time.current) }
      travel_to(t0 + 2.minutes) { sample! }

      travel_to(t0 + 3.minutes) { create_attempt(performed_at: Time.current) }
      travel_to(t0 + 4.minutes) { sample! }

      refresh!

      expect(Syrus::Metrics.render).to include('syrus_auto_retry_attempts_total{skip_reason="none"} 2')
    end

    it "does not count a pending attempt that has neither performed nor been skipped yet" do
      t0 = Time.current
      travel_to(t0) { sample! }
      travel_to(t0 + 1.minute) { create_attempt }
      travel_to(t0 + 2.minutes) { sample! }
      refresh!

      expect(Syrus::Metrics.render).not_to include("syrus_auto_retry_attempts_total{")
    end

    # One unreachable source costs its own metrics, not the whole tick --
    # same degradation posture as Metrics::QueueSampler/Metrics::LandingSampler.
    it "degrades the recurring-job reading without losing provider_sessions gauges" do
      queue_source.recurring_job_last_success = ActiveRecord::StatementInvalid.new("no such table")

      run = Factories.job_with_run.runs.first
      ProviderSession.create!(resumable: run, session_id: "s1", transcript_jsonl: "hello")

      expect { sample! }.not_to raise_error
      refresh!

      rendered = Syrus::Metrics.render
      expect(rendered).to include("syrus_provider_sessions_bytes 5")
      expect(rendered).not_to include("syrus_recurring_job_last_success_seconds{")
    end

    it "degrades the auto-retry reading without losing the recurring-job or provider_sessions gauges" do
      # See the floor() note above -- travel_to's mocked "now" is truncated
      # to whole seconds, so t0 needs to start there too.
      t0 = Time.current.floor
      travel_to(t0) { sample! } # bootstrap the cursor with a healthy source

      source = FakeMaintenanceSource.new
      source.settled_auto_retry_attempts = ActiveRecord::StatementInvalid.new("no such table")
      queue_source.recurring_job_last_success = { "prune_provider_sessions" => t0 }

      travel_to(t0 + 1.minute) do
        expect { sample!(source: source) }.not_to raise_error
        refresh!
      end

      expect(Syrus::Metrics.render).to include('syrus_recurring_job_last_success_seconds{job="prune_provider_sessions"} 60')
    end
  end

  describe "#refresh_gauges!" do
    it "reports nothing rather than zeroes when no sample has been taken" do
      expect(refresh!).to be(false)
      expect(Syrus::Metrics.render).not_to include("syrus_provider_sessions_rows")
    end
  end
end
