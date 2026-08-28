require "rails_helper"

RSpec.describe LandedCommit, type: :model do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_record(user: user, repository: repository, issue_number: 1) }
  let(:epic) { Factories.epic(user: user, repository: repository) }

  def valid_attrs(overrides = {})
    { landable: job, sha: "a" * 40, kind: "implementation", position: 0 }.merge(overrides)
  end

  it "is valid with all required attributes" do
    expect(described_class.new(valid_attrs)).to be_valid
  end

  it "accepts all known kinds" do
    LandedCommit::KINDS.each_with_index do |kind, i|
      expect(described_class.new(valid_attrs(sha: "b" * 39 + i.to_s, kind: kind))).to be_valid
    end
  end

  it "rejects unknown kinds" do
    expect(described_class.new(valid_attrs(kind: "bogus"))).not_to be_valid
    expect(described_class.new(valid_attrs(kind: nil))).not_to be_valid
  end

  it "requires sha and position" do
    expect(described_class.new(valid_attrs(sha: nil))).not_to be_valid
    expect(described_class.new(valid_attrs(position: nil))).not_to be_valid
  end

  it "enforces sha uniqueness" do
    described_class.create!(valid_attrs)

    expect(described_class.new(valid_attrs(landable: epic, kind: "integration_merge"))).not_to be_valid
  end

  it "belongs to a Job landable" do
    commit = described_class.create!(valid_attrs)

    expect(commit.landable).to eq(job)
  end

  it "belongs to an Epic landable" do
    commit = described_class.create!(valid_attrs(landable: epic, kind: "integration_merge", sha: "c" * 40))

    expect(commit.landable).to eq(epic)
  end
end
