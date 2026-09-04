require "rails_helper"

RSpec.describe Admission::FairShare do
  let(:user) { Factories.user }
  let(:other) { Factories.user }

  def running_runs!(owner, count)
    count.times do
      job = Factories.job_with_run(user: owner)
      job.runs.first.update!(state: "running", user: owner)
    end
  end

  it "does not limit anyone when there is no global cap" do
    result = described_class.for(user: user, limit: 0)

    expect(result).not_to be_over_share
    expect(result).to be_unlimited
  end

  # An instance with one active user should let that user use the whole cap;
  # the share only bites when someone else is actually waiting.
  it "lets a sole contender use the whole cap" do
    running_runs!(user, 4)

    expect(described_class.for(user: user, limit: 4)).not_to be_over_share
  end

  it "splits the cap between users who are actually contending" do
    running_runs!(user, 2)
    running_runs!(other, 1)

    result = described_class.for(user: user, limit: 4)

    expect(result.contenders).to eq(2)
    expect(result.share).to eq(2)
    expect(result).to be_over_share
  end

  it "leaves a user inside their share alone" do
    running_runs!(user, 1)
    running_runs!(other, 1)

    expect(described_class.for(user: user, limit: 4)).not_to be_over_share
  end

  # A share that rounded to zero would defer work forever rather than slowly.
  it "never computes a share below one" do
    running_runs!(user, 1)
    running_runs!(other, 1)

    expect(described_class.for(user: user, limit: 1).share).to eq(1)
  end

  it "excludes the run being admitted from its own contention count" do
    running_runs!(user, 1)
    run = ::Run.running_agent_runs.first

    expect(described_class.for(user: user, limit: 2, excluding_run_id: run.id).active).to eq(0)
  end
end
