require "rails_helper"

RSpec.describe EpicDependency do
  let(:user) { Factories.user }

  it "accepts depends_on_job as a single target" do
    epic = Factories.epic(user: user)
    job = Factories.job_record(user: user, repository: epic.repository)

    dependency = described_class.new(epic: epic, depends_on_job: job)

    expect(dependency).to be_valid
  end

  it "rejects rows with both target FKs set" do
    epic = Factories.epic(user: user)
    upstream_epic = Factories.epic(user: user, repository: epic.repository)
    job = Factories.job_record(user: user, repository: epic.repository)

    dependency = described_class.new(epic: epic, depends_on_epic: upstream_epic, depends_on_job: job)

    expect(dependency).not_to be_valid
    expect(dependency.errors[:base]).to include("must reference exactly one dependency target")
  end

  it "delegates Job target success to the Job dependency contract" do
    epic = Factories.epic(user: user)
    job = Factories.job_record(user: user, repository: epic.repository, state: "queued")
    dependency = described_class.create!(epic: epic, depends_on_job: job)

    expect(dependency).not_to be_dependency_succeeded

    job.update!(closure_reason: "pr_merged")
    job.close!

    expect(dependency.reload).to be_dependency_succeeded
  end

  it "rejects self references" do
    epic = Factories.epic(user: user)

    dependency = described_class.new(epic: epic, depends_on_epic: epic)

    expect(dependency).not_to be_valid
    expect(dependency.errors[:depends_on_epic]).to include("can't be the same Epic")
  end

  it "rejects cycles" do
    root = Factories.epic(user: user)
    middle = Factories.epic(user: user)
    leaf = Factories.epic(user: user)
    described_class.create!(epic: leaf, depends_on_epic: middle)
    described_class.create!(epic: middle, depends_on_epic: root)

    dependency = described_class.new(epic: root, depends_on_epic: leaf)

    expect(dependency).not_to be_valid
    expect(dependency.errors[:depends_on_epic]).to include("would create a cycle")
  end
end
