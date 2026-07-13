require "rails_helper"

RSpec.describe JobTag, type: :model do
  let(:user) { Factories.user }
  let(:job) { Factories.job_record(user: user) }
  let(:tag) { Factories.tag(user: user) }

  it "is valid when tag and job belong to the same user" do
    expect(described_class.new(job: job, tag: tag)).to be_valid
  end

  it "is invalid when tag belongs to a different user" do
    other_user = Factories.user
    other_tag = Factories.tag(user: other_user)

    record = described_class.new(job: job, tag: other_tag)

    expect(record).not_to be_valid
    expect(record.errors[:tag]).to include("must belong to the job owner")
  end

  it "enforces uniqueness of tag per job" do
    described_class.create!(job: job, tag: tag)

    duplicate = described_class.new(job: job, tag: tag)

    expect(duplicate).not_to be_valid
  end

  it "allows the same tag to be applied to different jobs" do
    other_job = Factories.job_record(user: user)
    described_class.create!(job: job, tag: tag)

    second = described_class.new(job: other_job, tag: tag)
    expect(second).to be_valid
  end

  it "allows different tags to be applied to the same job" do
    tag2 = Factories.tag(user: user)
    described_class.create!(job: job, tag: tag)

    second = described_class.new(job: job, tag: tag2)
    expect(second).to be_valid
  end
end
