require "rails_helper"

RSpec.describe Coworkers::MetricsDashboardSummary do
  let(:cache) { ActiveSupport::Cache::MemoryStore.new }

  before do
    allow(Rails).to receive(:cache).and_return(cache)
    cache.write(Coworkers::MetricsSampler::CACHE_KEY, {
      "coworkers" => {
        "fresh" => { "journaling_state" => "scheduled", "journaling_age" => 2.hours, "unsaved_age" => 0, "weekly_spend" => 12.5 },
        "stale" => { "journaling_state" => "auto_paused", "journaling_age" => 40.hours, "unsaved_age" => 2.hours, "weekly_spend" => 0 }
      }
    })
  end

  it "preserves active state and highlights stale health rows" do
    summary = described_class.build
    fresh, stale = summary.fetch(:rows)

    expect(fresh).to include(key: "fresh", stale: false)
    expect(fresh.dig(:values, :journaling_state)).to eq("Scheduled")
    expect(stale).to include(key: "stale", stale: true)
    expect(stale.dig(:values, :journaling_state)).to eq("Auto-paused")
    expect(fresh.dig(:values, :spend)).to include("12.50")
  end

  it "uses plugin-owned translations and locale-sensitive currency formatting" do
    german = I18n.with_locale(:de) { described_class.build }
    latin = I18n.with_locale(:la) { described_class.build }

    expect(german[:title]).to eq("Coworker-Zustand")
    expect(german.dig(:rows, 0, :values, :journaling_state)).to eq("Geplant")
    expect(latin[:title]).to eq("Salus collegarum")
    expect(latin.dig(:rows, 0, :values, :journaling_state)).to eq("Statutum")
  end
end
