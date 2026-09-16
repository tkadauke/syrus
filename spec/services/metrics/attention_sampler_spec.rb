require "rails_helper"

# EscalationsPerLanding and AttentionItem are ordinary ActiveRecord-backed
# services (unlike solid_queue_*, see CLAUDE.md), so both are exercised
# directly with real records here; only the per-source degradation guard
# needs a stand-in.
RSpec.describe Metrics::AttentionSampler do
  class FakeEscalationsPerLanding
    attr_writer :ratio

    def call = resolve

    private

    def resolve
      raise @ratio if @ratio.is_a?(Exception)

      Metrics::EscalationsPerLanding::Result.new(
        escalations: 0, landings: 0, ratio: @ratio, from: 7.days.ago, to: Time.current, by_problem_code: {}
      )
    end
  end

  let(:cache) { ActiveSupport::Cache::MemoryStore.new }

  around do |example|
    original = Syrus::Metrics.registry
    Syrus::Metrics.reset!
    described_class.declare_metrics!
    example.run
  ensure
    Syrus::Metrics.instance_variable_set(:@registry, original)
  end

  before { allow(Rails).to receive(:cache).and_return(cache) }

  # Metrics::EscalationsPerLanding.decisions/landed_workflows are plain
  # ActiveRecord queries with no launcher involvement, but building a Job via
  # `Factories.job` routes through the full WorkUnits launcher/admission
  # path, which references `syrus_admission_decisions_total` -- a metric this
  # spec's registry reset (see `around` above) has wiped. `job_with_run`
  # builds the minimal graph without that launcher, the same seam
  # Metrics::ResilienceSampler's and Metrics::MaintenanceSampler's own specs
  # use for exactly this reason.
  def landing!(finished_at: 1.hour.ago, state: "succeeded")
    job = Factories.job_with_run
    job.workflows.create!(trigger_kind: "auto_merge", state: state, user: job.user, finished_at: finished_at)
    job
  end

  def escalation!(created_at: 1.hour.ago, problem_code: "grader_failure", state: "open")
    AttentionItem.create!(
      problem_code: problem_code, signature: "#{problem_code}:#{SecureRandom.hex(4)}",
      title: "t", created_at: created_at, state: state
    )
  end

  describe "#sample!" do
    it "reports the ratio when work landed and cost some attention" do
      landing!
      3.times { escalation!(created_at: Time.current) }

      described_class.sample!
      described_class.refresh_gauges!

      expect(Syrus::Metrics.render).to include("syrus_escalations_per_landing_ratio 3")
    end

    it "reports zero when work landed without costing anyone attention" do
      landing!

      described_class.sample!
      described_class.refresh_gauges!

      expect(Syrus::Metrics.render).to include("syrus_escalations_per_landing_ratio 0")
    end

    # An infinity would read as a number; a 0 would read as "the ladder is
    # working great." Neither is honest when there is simply no data.
    it "omits the ratio rather than reporting zero when nothing landed in the window" do
      escalation!

      described_class.sample!
      described_class.refresh_gauges!

      expect(Syrus::Metrics.render).not_to include("syrus_escalations_per_landing_ratio")
    end

    it "clears a previously reported ratio once a later tick has nothing to report" do
      landing!
      escalation!(created_at: Time.current)

      described_class.sample!
      described_class.refresh_gauges!
      expect(Syrus::Metrics.render).to include("syrus_escalations_per_landing_ratio 1")

      no_ratio = FakeEscalationsPerLanding.new.tap { |f| f.ratio = nil }
      described_class.sample!(escalations_per_landing: no_ratio)
      described_class.refresh_gauges!

      expect(Syrus::Metrics.render).not_to include("syrus_escalations_per_landing_ratio")
    end

    # A dead sampler must not leave the last real ratio rendering forever --
    # that reads as "still healthy" through the exact outage this gauge
    # exists to surface.
    it "clears the ratio once the cached sample has expired" do
      landing!
      escalation!(created_at: Time.current)
      described_class.sample!
      described_class.refresh_gauges!
      expect(Syrus::Metrics.render).to include("syrus_escalations_per_landing_ratio 1")

      cache.clear

      described_class.refresh_gauges!

      expect(Syrus::Metrics.render).not_to include("syrus_escalations_per_landing_ratio")
    end

    it "counts currently open attention items by problem code" do
      escalation!(problem_code: "grader_failure")
      escalation!(problem_code: "grader_failure")
      escalation!(problem_code: "timeout")
      escalation!(problem_code: "timeout", state: "decided")

      described_class.sample!
      described_class.refresh_gauges!

      rendered = Syrus::Metrics.render
      expect(rendered).to include('syrus_attention_items_open_total{problem_code="grader_failure"} 2')
      expect(rendered).to include('syrus_attention_items_open_total{problem_code="timeout"} 1')
    end

    it "excludes an expired attention item from the open count" do
      escalation!(problem_code: "timeout").update!(expires_at: 1.minute.ago)

      described_class.sample!
      described_class.refresh_gauges!

      expect(Syrus::Metrics.render).not_to include("syrus_attention_items_open_total{")
    end

    # One unreachable source costs its own gauge, not the whole sample -- same
    # degradation posture as Metrics::QueueSampler/Metrics::ResilienceSampler.
    it "degrades the ratio reading without losing the open-attention-item gauge" do
      escalation!(problem_code: "timeout")
      failing = FakeEscalationsPerLanding.new.tap { |f| f.ratio = ActiveRecord::StatementInvalid.new("no such table") }

      expect { described_class.sample!(escalations_per_landing: failing) }.not_to raise_error
      described_class.refresh_gauges!

      rendered = Syrus::Metrics.render
      expect(rendered).not_to include("syrus_escalations_per_landing_ratio")
      expect(rendered).to include('syrus_attention_items_open_total{problem_code="timeout"} 1')
    end
  end

  describe "#refresh_gauges!" do
    it "reports nothing rather than zeroes when no sample has been taken" do
      expect(described_class.refresh_gauges!).to be(false)

      rendered = Syrus::Metrics.render
      expect(rendered).not_to include("syrus_escalations_per_landing_ratio")
      expect(rendered).not_to include("syrus_attention_items_open_total{")
    end
  end
end
