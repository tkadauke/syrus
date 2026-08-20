require "rails_helper"

RSpec.describe MergeTrain do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:epic) { Factories.epic(user: user, repository: repository) }

  def train
    MergeTrain.create!(epic: epic, repository: repository, base_branch: "master")
  end

  it "defaults to the building state and is not terminal" do
    expect(train.state).to eq("building")
    expect(train).not_to be_terminal
  end

  it "orders members by position and exposes their Jobs" do
    t = train
    j1 = Factories.job_record(user: user, repository: repository, epic: epic, issue_number: 1, state: "approved")
    j2 = Factories.job_record(user: user, repository: repository, epic: epic, issue_number: 2, state: "approved")
    MergeTrainMember.create!(merge_train: t, job: j2, position: 1)
    MergeTrainMember.create!(merge_train: t, job: j1, position: 0)

    expect(t.member_jobs.map(&:id)).to eq([ j1.id, j2.id ])
  end

  it "reports terminal states" do
    t = train
    t.update!(state: "succeeded")
    expect(t).to be_terminal
    expect(MergeTrain.active).not_to include(t)
  end

  it "defaults merge_train settings to disabled" do
    expect(AppSetting.merge_train_enabled?).to be(false)
    expect(AppSetting.merge_train_max_size).to eq(20)
  end

  describe "epic-backed vs. bundle-backed validation" do
    it "is valid when epic-backed (epic present, priority nil)" do
      t = MergeTrain.new(epic: epic, repository: repository, base_branch: "master")

      expect(t).to be_valid
    end

    it "is valid when bundle-backed (epic nil, priority present)" do
      t = MergeTrain.new(epic: nil, repository: repository, base_branch: "master", priority: "urgent")

      expect(t).to be_valid
    end

    it "is invalid when both epic and priority are present" do
      t = MergeTrain.new(epic: epic, repository: repository, base_branch: "master", priority: "urgent")

      expect(t).not_to be_valid
      expect(t.errors[:base]).to include("must not be both epic-backed and bundle-backed")
    end

    it "is invalid when neither epic nor priority is present" do
      t = MergeTrain.new(epic: nil, repository: repository, base_branch: "master")

      expect(t).not_to be_valid
      expect(t.errors[:base]).to include("must be either epic-backed (epic present) or bundle-backed (priority present)")
    end

    it "accepts every Job priority value for bundle-backed trains" do
      Job::PRIORITIES.each do |priority|
        t = MergeTrain.new(epic: nil, repository: repository, base_branch: "master", priority: priority)

        expect(t).to be_valid
      end
    end

    it "rejects a priority value outside Job::PRIORITIES" do
      t = MergeTrain.new(epic: nil, repository: repository, base_branch: "master", priority: "whenever")

      expect(t).not_to be_valid
      expect(t.errors[:priority]).to include("is not included in the list")
    end
  end
end
