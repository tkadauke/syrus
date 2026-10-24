require "rails_helper"

RSpec.describe AttentionReport::VisitStatistics do
  let(:user) { Factories.user }

  def sample(started_at:, active_ms:, job_id: 1, route_id: "job.review")
    UiEngagementSample.create!(
      user: user,
      route_id: route_id,
      route_params: route_id == "chat.show" ? { chat_id: job_id } : { job_id: job_id },
      started_at: started_at,
      ended_at: started_at + 10.seconds,
      active_ms: active_ms,
      visible_ms: [ active_ms, 10.seconds.in_milliseconds ].max
    )
  end

  it "drops tiny visits, caps outliers, and merges near-adjacent visits to the same subject" do
    start = 1.hour.ago
    sample(started_at: start, active_ms: 2_999)
    sample(started_at: start + 1.minute, active_ms: 5_000)
    sample(started_at: start + 20.seconds, active_ms: 4_000)
    sample(started_at: start + 3.minutes, active_ms: 2.hours.in_milliseconds, job_id: 2)

    visits = described_class.new(UiEngagementSample.where(user: user)).cleaned

    expect(visits.map(&:active_ms)).to contain_exactly(9_000, 30.minutes.in_milliseconds)
  end

  it "returns not-enough-data markers for tiny samples and nearest-rank percentiles once sufficient" do
    base = 1.hour.ago
    [ 3_000, 4_000, 5_000, 6_000 ].each_with_index { |ms, index| sample(started_at: base + index.minutes, active_ms: ms, job_id: index + 1) }
    result = described_class.new(UiEngagementSample.where(user: user)).as_json.fetch("job.review")
    expect(result[:p50_active_ms]).to eq(status: "not_enough_data", sample_count: 4)

    sample(started_at: base + 5.minutes, active_ms: 100_000, job_id: 9)
    result = described_class.new(UiEngagementSample.where(user: user)).as_json.fetch("job.review")
    expect(result).to include(sample_count: 5, enough_data: true)
    expect(result[:p50_active_ms]).to include(status: "available", value_ms: 5_000, sample_count: 5)
    expect(result[:p90_active_ms]).to include(status: "available", value_ms: 100_000, sample_count: 5)
  end
end
