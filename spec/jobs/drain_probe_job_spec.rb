require "rails_helper"

RSpec.describe DrainProbeJob do
  it "holds a run worker thread for the requested time" do
    job = described_class.new
    allow(job).to receive(:sleep)

    job.perform(600)

    expect(job).to have_received(:sleep).with(600)
    expect(job.queue_name).to eq("runs")
  end

  it "never holds one longer than two hours, or a negative time" do
    job = described_class.new
    allow(job).to receive(:sleep)

    job.perform(10 * 24 * 3600)
    job.perform(-5)

    expect(job).to have_received(:sleep).with(2.hours.to_i).ordered
    expect(job).to have_received(:sleep).with(0).ordered
  end
end
