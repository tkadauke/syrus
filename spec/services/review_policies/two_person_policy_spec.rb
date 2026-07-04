require "rails_helper"

RSpec.describe ReviewPolicies::TwoPersonPolicy do
  let(:owner) { Factories.user }
  let(:other) { Factories.user }
  let(:repo) { Factories.repository(user: owner, review_policy: "two_person") }

  def job_with_approvals(*approvers)
    job = Factories.job_record(user: owner, owner_user: owner, repository: repo, state: "implemented")
    approvers.each { |u| JobApproval.create!(job: job, user: u) }
    job
  end

  context "with no approvals" do
    subject { described_class.new(job_with_approvals) }
    it { is_expected.not_to be_satisfied }
  end

  context "with only owner approval" do
    subject { described_class.new(job_with_approvals(owner)) }
    it { is_expected.not_to be_satisfied }
  end

  context "with only a non-owner approval" do
    subject { described_class.new(job_with_approvals(other)) }
    it { is_expected.not_to be_satisfied }
  end

  context "with owner and another user's approval" do
    subject { described_class.new(job_with_approvals(owner, other)) }
    it { is_expected.to be_satisfied }
  end
end
