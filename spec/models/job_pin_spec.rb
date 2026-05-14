require "rails_helper"

RSpec.describe JobPin, type: :model do
  it "enforces one pin per user/job" do
    user = Factories.user
    repo = Factories.repository(user: user)
    job = Factories.job(repository: repo)
    Factories.job_pin(user: user, job: job)

    duplicate = described_class.new(user: user, job: job)

    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:job_id]).to be_present
  end

  it "does not allow a user to pin another user's job" do
    user = Factories.user
    other = Factories.user
    other_repo = Factories.repository(user: other)
    other_job = Factories.job(repository: other_repo)

    pin = described_class.new(user: user, job: other_job)

    expect(pin).not_to be_valid
    expect(pin.errors[:job]).to include("must belong to the user")
  end
end
