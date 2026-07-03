require "rails_helper"

RSpec.describe JobApproval do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user) }
  let(:job) { Factories.job_record(user: user, repository: repo, state: "implemented") }

  it "creates with required attributes" do
    approval = JobApproval.create!(job: job, user: user)
    expect(approval.approved_at).to be_present
    expect(approval.job).to eq(job)
    expect(approval.user).to eq(user)
  end

  it "sets approved_at automatically on create" do
    approval = JobApproval.new(job: job, user: user)
    approval.save!
    expect(approval.approved_at).to be_within(5.seconds).of(Time.current)
  end

  it "enforces uniqueness of user per job" do
    JobApproval.create!(job: job, user: user)
    duplicate = JobApproval.new(job: job, user: user)
    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:user_id]).to be_present
  end

  it "allows the same user to approve different jobs" do
    other_job = Factories.job_record(user: user, repository: repo, state: "implemented")
    JobApproval.create!(job: job, user: user)
    expect { JobApproval.create!(job: other_job, user: user) }.not_to raise_error
  end
end
