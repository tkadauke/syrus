require "rails_helper"

RSpec.describe SpendingInsights::MetricsSampler do
  include ActiveSupport::Testing::TimeHelpers

  let(:cache) { ActiveSupport::Cache::MemoryStore.new }

  around do |example|
    original = Syrus::Metrics.registry
    Syrus::Metrics.reset!
    Syrus::Metrics.declare_plugin("spending_insights") do
      counter :run_cost_usd_total, tags: %i[provider trigger_kind]
    end
    example.run
  ensure
    Syrus::Metrics.instance_variable_set(:@registry, original)
  end

  before { allow(Rails).to receive(:cache).and_return(cache) }

  describe "#sample!" do
    it "bootstraps the cursor on the first tick without instrumenting existing history" do
      t0 = Time.current
      travel_to(t0 - 1.hour) do
        job_with_run(run_attrs: { state: "succeeded", trigger_kind: "initial", agent_provider: "claude", cost_usd: 1.5, finished_at: Time.current })
      end

      travel_to(t0) { described_class.sample! }
      described_class.refresh_gauges!

      expect(Syrus::Metrics.render).not_to include("syrus_spending_insights_run_cost_usd_total{")
    end

    # The bug this whole class exists to avoid: #sample! runs on a worker's
    # tick, while /metrics is served by web with a completely separate
    # in-process registry. Only #refresh_gauges!, called from the scrape
    # path, may touch the live counter -- and only from the cache.
    it "does not mutate the live counter directly -- only refresh_gauges! may" do
      t0 = Time.current
      travel_to(t0) { described_class.sample! } # bootstrap

      travel_to(t0 + 1.minute) do
        job_with_run(run_attrs: { state: "succeeded", trigger_kind: "initial", agent_provider: "claude", cost_usd: 2.5, finished_at: Time.current })
      end
      travel_to(t0 + 2.minutes) { described_class.sample! }

      expect(Syrus::Metrics.render).not_to include("syrus_spending_insights_run_cost_usd_total{")
    end

    it "sums a Run's cost into the counter, tagged by provider and trigger_kind, once refresh_gauges! runs" do
      t0 = Time.current
      travel_to(t0) { described_class.sample! } # bootstrap

      travel_to(t0 + 1.minute) do
        job_with_run(run_attrs: { state: "succeeded", trigger_kind: "initial", agent_provider: "claude", cost_usd: 2.5, finished_at: Time.current })
      end
      travel_to(t0 + 2.minutes) { described_class.sample! }
      described_class.refresh_gauges!

      expect(Syrus::Metrics.render).to include('syrus_spending_insights_run_cost_usd_total{provider="claude",trigger_kind="initial"} 2.5')
    end

    it "accumulates across ticks so a single refresh reflects the full total, not just the latest tick's delta" do
      t0 = Time.current
      travel_to(t0) { described_class.sample! }

      travel_to(t0 + 1.minute) do
        job_with_run(run_attrs: { state: "succeeded", trigger_kind: "initial", agent_provider: "claude", cost_usd: 1.25, finished_at: Time.current })
      end
      travel_to(t0 + 2.minutes) { described_class.sample! }

      travel_to(t0 + 3.minutes) do
        job_with_run(run_attrs: { state: "succeeded", trigger_kind: "initial", agent_provider: "claude", cost_usd: 0.75, finished_at: Time.current })
      end
      travel_to(t0 + 4.minutes) { described_class.sample! }

      described_class.refresh_gauges!

      expect(Syrus::Metrics.render).to include('syrus_spending_insights_run_cost_usd_total{provider="claude",trigger_kind="initial"} 2')
    end

    it "does not double-count a Run already instrumented on a prior tick" do
      t0 = Time.current
      travel_to(t0) { described_class.sample! }

      travel_to(t0 + 1.minute) do
        job_with_run(run_attrs: { state: "failed", trigger_kind: "pr_comment", agent_provider: "codex", cost_usd: 4.0, finished_at: Time.current })
      end
      travel_to(t0 + 2.minutes) { described_class.sample! }
      travel_to(t0 + 3.minutes) { described_class.sample! }

      described_class.refresh_gauges!
      described_class.refresh_gauges!

      expect(Syrus::Metrics.render).to include('syrus_spending_insights_run_cost_usd_total{provider="codex",trigger_kind="pr_comment"} 4')
    end

    it "does not count a Run with no recorded cost" do
      t0 = Time.current
      travel_to(t0) { described_class.sample! }

      travel_to(t0 + 1.minute) do
        job_with_run(run_attrs: { state: "succeeded", trigger_kind: "initial", agent_provider: "claude", cost_usd: nil, finished_at: Time.current })
      end
      travel_to(t0 + 2.minutes) { described_class.sample! }
      described_class.refresh_gauges!

      expect(Syrus::Metrics.render).not_to include("syrus_spending_insights_run_cost_usd_total{")
    end

    it "degrades without raising when the source is unreachable" do
      allow(Run).to receive(:terminal).and_raise(ActiveRecord::StatementInvalid, "no such table")
      travel_to(Time.current) { described_class.sample! } # bootstrap
      travel_to(Time.current + 1.minute) { expect { described_class.sample! }.not_to raise_error }
    end
  end

  describe "#refresh_gauges!" do
    it "reports nothing rather than zero when no sample has been taken" do
      expect(described_class.refresh_gauges!).to be(false)
      expect(Syrus::Metrics.render).not_to include("syrus_spending_insights_run_cost_usd_total")
    end
  end
end
