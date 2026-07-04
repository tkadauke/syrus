require "rails_helper"

RSpec.describe ReviewPolicies::FinalSayPolicy do
  let(:owner) { Factories.user }
  let(:final_approver) { Factories.user }
  let(:random_user) { Factories.user }

  def repo_with_final_approvers(*fas)
    r = Factories.repository(user: owner, review_policy: "final_say")
    fas.each { |u| RepositoryFinalApprover.create!(repository: r, user: u) }
    r
  end

  def job_with_approvals(repo, *approvers)
    job = Factories.job_record(user: owner, owner_user: owner, repository: repo, state: "implemented")
    approvers.each { |u| JobApproval.create!(job: job, user: u) }
    job
  end

  context "when owner is a final approver (collapses to self)" do
    let(:repo) { repo_with_final_approvers(owner) }

    it "is not satisfied with no approvals" do
      expect(described_class.new(job_with_approvals(repo))).not_to be_satisfied
    end

    it "is satisfied when only the owner approves" do
      expect(described_class.new(job_with_approvals(repo, owner))).to be_satisfied
    end

    it "returns waiting-for-owner description with no approvals" do
      expect(described_class.new(job_with_approvals(repo)).pending_description).to eq("Waiting for owner to approve")
    end

    it "returns nil description when owner has approved" do
      expect(described_class.new(job_with_approvals(repo, owner)).pending_description).to be_nil
    end
  end

  context "when owner is not a final approver" do
    let(:repo) { repo_with_final_approvers(final_approver) }

    it "is not satisfied with owner approval alone" do
      expect(described_class.new(job_with_approvals(repo, owner))).not_to be_satisfied
    end

    it "is not satisfied with final approver approval alone" do
      expect(described_class.new(job_with_approvals(repo, final_approver))).not_to be_satisfied
    end

    it "is not satisfied when owner and a non-final-approver have approved" do
      expect(described_class.new(job_with_approvals(repo, owner, random_user))).not_to be_satisfied
    end

    it "is satisfied when owner and a final approver have both approved" do
      expect(described_class.new(job_with_approvals(repo, owner, final_approver))).to be_satisfied
    end

    it "returns waiting-for-owner description with no approvals" do
      expect(described_class.new(job_with_approvals(repo)).pending_description).to eq("Waiting for owner approval")
    end

    it "returns waiting-for-final-approver description after owner approves" do
      expect(described_class.new(job_with_approvals(repo, owner)).pending_description).to eq("Waiting for final approver")
    end

    it "returns nil description when fully satisfied" do
      expect(described_class.new(job_with_approvals(repo, owner, final_approver)).pending_description).to be_nil
    end
  end
end
