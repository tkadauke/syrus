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

  it "rejects duplicate jobs within the same train" do
    described_class.create!(valid_attrs(position: 0))

    duplicate = described_class.new(valid_attrs(position: 1))

    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:job_id]).to be_present
  end

  it "rejects duplicate positions within the same train" do
    job2 = Factories.job_record(user: user, repository: repository, epic: epic, issue_number: 2)
    described_class.create!(valid_attrs(position: 0))

    duplicate = described_class.new(valid_attrs(job: job2, position: 0))

    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:position]).to be_present
  end

  it "enforces unique jobs per train at the database layer" do
    described_class.create!(valid_attrs(position: 0))

    expect {
      insert_member!(job_id: job.id, position: 1)
    }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "enforces unique positions per train at the database layer" do
    job2 = Factories.job_record(user: user, repository: repository, epic: epic, issue_number: 2)
    described_class.create!(valid_attrs(position: 0))

    expect {
      insert_member!(job_id: job2.id, position: 0)
    }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "allows the same job and position in different trains" do
    other_epic = Factories.epic(user: user, repository: repository, title: "Other epic")
    other_train = MergeTrain.create!(epic: other_epic, repository: repository, base_branch: "main")

    described_class.create!(valid_attrs(position: 0))

    other = described_class.new(valid_attrs(merge_train: other_train, position: 0))
    expect(other).to be_valid
  end

  def insert_member!(job_id:, position:)
    timestamp = Time.current

    described_class.insert_all!([
      {
        merge_train_id: merge_train.id,
        job_id: job_id,
        position: position,
        state: "included",
        created_at: timestamp,
        updated_at: timestamp
      }
    ])
  end
end
