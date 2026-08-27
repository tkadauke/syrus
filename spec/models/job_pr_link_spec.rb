require "rails_helper"

RSpec.describe JobPrLink do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:other_repository) { Factories.repository(user: user, name: "other-repo") }
  let(:job) { Job.create!(user: user, repository: repository, issue_number: 1) }

  it "defaults metadata to an empty hash" do
    link = described_class.new(job: job, role: "local")

    expect(link.metadata).to eq({})
  end

  it "requires a role" do
    link = described_class.new(job: job, role: nil)

    expect(link).not_to be_valid
    expect(link.errors[:role]).to include("can't be blank")
  end

  it "rejects an unrecognized role" do
    link = described_class.new(job: job, role: "not_a_real_role")

    expect(link).not_to be_valid
    expect(link.errors[:role]).to include("is not included in the list")
  end

  it "accepts every taxonomy role" do
    described_class::ROLES.each do |role|
      link = described_class.new(job: job, role: role)
      expect(link).to be_valid
    end
  end

  it "enforces one link per job/role" do
    described_class.create!(job: job, role: "local", pr_number: 1)
    duplicate = described_class.new(job: job, role: "local", pr_number: 2)

    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:role]).to include("has already been taken")
  end

  it "allows the same role on different jobs" do
    other_job = Job.create!(user: user, repository: repository, issue_number: 2)
    described_class.create!(job: job, role: "local", pr_number: 1)
    other_link = described_class.new(job: other_job, role: "local", pr_number: 2)

    expect(other_link).to be_valid
  end

  describe ".record!" do
    it "creates a new link when none exists for the job/role" do
      link = described_class.record!(
        job: job,
        role: "local",
        source_repository_id: repository.id,
        source_ref: "syrus/direct-1",
        target_repository_id: other_repository.id,
        target_ref: "main",
        pr_number: 42
      )

      expect(link).to be_persisted
      expect(job.pr_links.reload.sole).to eq(link)
      expect(link.pr_number).to eq(42)
      expect(link.target_repository).to eq(other_repository)
    end

    it "updates the existing link in place instead of creating a duplicate" do
      described_class.record!(job: job, role: "local", pr_number: 42, source_ref: "syrus/direct-1")

      expect {
        described_class.record!(job: job, role: "local", pr_number: 43, source_ref: "syrus/direct-1")
      }.not_to change { JobPrLink.count }

      link = job.pr_links.sole
      expect(link.pr_number).to eq(43)
    end
  end
end
