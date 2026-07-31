require "rails_helper"

RSpec.describe WorkerHealthSampleAnalysis do
  def sample(**attrs)
    WorkerHostHealthSample.new({
      hostname: "worker-a",
      role: "worker",
      version: "abc123",
      observed_at: Time.zone.parse("2026-07-31T12:00:00Z")
    }.merge(attrs))
  end

  describe ".health_for" do
    it "applies the shared worker pressure thresholds" do
      health = described_class.health_for(sample(cpu_used_percent: 92.0, io_pressure_some: 55.0))

      expect(health).to eq(
        level: "critical",
        reasons: [
          "cpu 92.0% >= 90%",
          "IO pressure 55.0% >= 50%"
        ]
      )
    end
  end

  describe ".summarize" do
    it "summarizes the wide sample fields consistently" do
      samples = [
        sample(observed_at: Time.zone.parse("2026-07-31T12:00:00Z"), load_1m: 1.0, load_5m: 1.5, load_15m: 2.0, cpu_pressure_full: 0.2, io_pressure_full: 0.4),
        sample(observed_at: Time.zone.parse("2026-07-31T12:01:00Z"), load_1m: 2.0, load_5m: 2.5, load_15m: 3.0, cpu_pressure_full: 0.6, io_pressure_full: 0.8)
      ]

      summary = described_class.summarize(samples)

      expect(summary).to include(
        sample_count: 2,
        first_observed_at: "2026-07-31T12:00:00Z",
        last_observed_at: "2026-07-31T12:01:00Z",
        load_1m: { avg: 1.5, max: 2.0 },
        load_5m: { avg: 2.0, max: 2.5 },
        load_15m: { avg: 2.5, max: 3.0 },
        cpu_pressure_full: { avg: 0.4, max: 0.6 },
        io_pressure_full: { avg: 0.6, max: 0.8 }
      )
    end
  end
end
