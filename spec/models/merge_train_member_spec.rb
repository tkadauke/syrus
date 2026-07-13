require "rails_helper"

RSpec.describe MergeTrainMember, type: :model do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:epic) { Factories.epic(user: user, repository: repository) }
  let(:merge_train) { MergeTrain.create!(epic: epic, repository: repository, base_branch: "main") }
  let(:job) { Factories.job_record(user: user, repository: repository, epic: epic, issue_number: 1) }

  def valid_attrs(overrides = {})
    { merge_train: merge_train, job: job, position: 0, state: "included" }.merge(overrides)
  end

  it "is valid with all required attributes" do
    expect(described_class.new(valid_attrs)).to be_valid
  end

  it "accepts all known states" do
    MergeTrainMember::STATES.each do |state|
      expect(described_class.new(valid_attrs(state: state))).to be_valid
    end
  end

  it "rejects unknown states" do
    expect(described_class.new(valid_attrs(state: "pending"))).not_to be_valid
    expect(described_class.new(valid_attrs(state: nil))).not_to be_valid
  end

  it "requires position" do
    expect(described_class.new(valid_attrs(position: nil))).not_to be_valid
  end

  it "belongs to a merge train and a job" do
    member = described_class.create!(valid_attrs)

    expect(member.merge_train).to eq(merge_train)
    expect(member.job).to eq(job)
  end

  it "allows members with different positions in the same train" do
    job2 = Factories.job_record(user: user, repository: repository, epic: epic, issue_number: 2)
    described_class.create!(valid_attrs(position: 0))

    second = described_class.new(valid_attrs(job: job2, position: 1))
    expect(second).to be_valid
  end
end
