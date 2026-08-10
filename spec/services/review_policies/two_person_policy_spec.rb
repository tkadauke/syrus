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

  describe "#multi_person?" do
    subject { described_class.new(job_with_approvals) }
    it { is_expected.to be_multi_person }
  end

  context "with no approvals" do
    subject { described_class.new(job_with_approvals) }
    it { is_expected.not_to be_satisfied }
    it { expect(subject.pending_description).to eq("Waiting for owner approval") }
  end

  context "with only owner approval" do
    subject { described_class.new(job_with_approvals(owner)) }
    it { is_expected.not_to be_satisfied }
    it { expect(subject.pending_description).to eq("Waiting for one additional approval") }
  end

  context "with only a non-owner approval" do
    subject { described_class.new(job_with_approvals(other)) }
    it { is_expected.not_to be_satisfied }
    it { expect(subject.pending_description).to eq("Waiting for owner approval") }
  end

  context "with owner and another user's approval" do
    subject { described_class.new(job_with_approvals(owner, other)) }
    it { is_expected.to be_satisfied }
    it { expect(subject.pending_description).to be_nil }
  end

  context "when owner_user_id is nil (falls back to user_id)" do
    def job_with_approvals(*approvers)
      job = Factories.job_record(user: owner, owner_user_id: nil, repository: repo, state: "implemented")
      approvers.each { |u| JobApproval.create!(job: job, user: u) }
      job
    end

    context "with no approvals" do
      subject { described_class.new(job_with_approvals) }
      it { is_expected.not_to be_satisfied }
      it { expect(subject.pending_description).to eq("Waiting for owner approval") }
    end

    context "with only the creator's approval" do
      subject { described_class.new(job_with_approvals(owner)) }
      it { is_expected.not_to be_satisfied }
      it { expect(subject.pending_description).to eq("Waiting for one additional approval") }
    end

    context "with creator and another user's approval" do
      subject { described_class.new(job_with_approvals(owner, other)) }
      it { is_expected.to be_satisfied }
      it { expect(subject.pending_description).to be_nil }
    end
  end
end
