# frozen_string_literal: true

require_relative "deploy_helper"

RSpec.describe Deploy::Duration do
  it "accepts a bare number of seconds" do
    expect(described_class.seconds("90")).to eq(90)
    expect(described_class.seconds(90)).to eq(90)
  end

  it "accepts compound durations" do
    expect(described_class.seconds("1m30s")).to eq(90)
    expect(described_class.seconds("1h30m")).to eq(5400)
    expect(described_class.seconds("2h")).to eq(7200)
  end

  # A leading zero used to make bash read a duration as octal, so these stayed
  # explicitly base-ten.
  it "reads digits as base ten" do
    expect(described_class.seconds("08")).to eq(8)
    expect(described_class.seconds("09m")).to eq(540)
  end

  it "rejects a malformed duration, naming the variable it came from" do
    expect { described_class.seconds("1h30x", name: "ROLLOUT_TIMEOUT") }
      .to raise_error(Deploy::Duration::Invalid, /ROLLOUT_TIMEOUT="1h30x"/)
  end

  it "rejects an empty duration rather than reading it as zero" do
    expect { described_class.seconds("") }.to raise_error(Deploy::Duration::Invalid)
  end

  it "renders a duration the way the operator wrote it" do
    expect(described_class.humanize(5400)).to eq("1h30m")
    expect(described_class.humanize(90)).to eq("1m30s")
    expect(described_class.humanize(0)).to eq("0s")
  end
end
