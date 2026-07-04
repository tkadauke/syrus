require "rails_helper"

RSpec.describe ReviewPolicies::SelfPolicy do
  let(:owner) { Factories.user }
  let(:other) { Factories.user }
  let(:repo) { Factories.repository(user: owner, review_policy: "self") }

  def job_with_approvals(*approvers)
    job = Factories.job_record(user: owner, owner_user: owner, repository: repo, state: "implemented")
    approvers.each { |u| JobApproval.create!(job: job, user: u) }
    job
  end

  subject(:policy) { described_class.new(job_with_approvals(*approvers)) }

  context "with no approvals" do
    let(:approvers) { [] }
    it { is_expected.not_to be_satisfied }
    it { expect(policy.pending_description).to eq("Waiting for owner to approve") }
  end

  context "with owner approval" do
    let(:approvers) { [owner] }
    it { is_expected.to be_satisfied }
    it { expect(policy.pending_description).to be_nil }
  end

  context "with only a non-owner approval" do
    let(:approvers) { [other] }
    it { is_expected.not_to be_satisfied }
    it { expect(policy.pending_description).to eq("Waiting for owner to approve") }
  end
end
