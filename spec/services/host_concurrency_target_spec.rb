require "rails_helper"
require "tmpdir"

RSpec.describe HostConcurrencyTarget do
  around do |example|
    Dir.mktmpdir("syrus-concurrency-spec") do |dir|
      @path = Pathname.new(dir).join("target.json")
      example.run
    end
  end

  let(:t0) { Time.zone.parse("2026-11-25 12:00:00") }

  def target(at, cpus: 4) = described_class.new(cpus: cpus, now: at, path: @path)

  it "starts at the worker's CPU count" do
    expect(target(t0).observe!(active: 0, pressured: false)).to eq(4)
  end

  it "grows by one when the worker is full and healthy, at most once per interval" do
    expect(target(t0).observe!(active: 4, pressured: false)).to eq(5)
    expect(target(t0 + 10.seconds).observe!(active: 5, pressured: false)).to eq(5)
    expect(target(t0 + described_class::ADJUST_INTERVAL).observe!(active: 5, pressured: false)).to eq(6)
  end

  it "does not grow while the worker is below its target" do
    expect(target(t0).observe!(active: 1, pressured: false)).to eq(4)
  end

  it "halves under pressure and never drops below one" do
    expect(target(t0).observe!(active: 4, pressured: true)).to eq(2)
    expect(target(t0 + 1.minute).observe!(active: 2, pressured: true)).to eq(1)
    expect(target(t0 + 2.minutes).observe!(active: 1, pressured: true)).to eq(1)
  end

  it "caps runaway growth" do
    now = t0
    20.times do
      target(now, cpus: 2).observe!(active: 100, pressured: false)
      now += described_class::ADJUST_INTERVAL
    end

    expect(target(now, cpus: 2).observe!(active: 100, pressured: false)).to eq(2 * described_class::MAX_TARGET_PER_CPU)
  end

  it "falls back to the CPU count when its state is unreadable" do
    @path.write("not json")

    expect(target(t0).observe!(active: 0, pressured: false)).to eq(4)
  end
end
