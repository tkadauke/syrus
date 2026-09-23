require "rails_helper"

RSpec.describe JobChannel, type: :channel do
  let(:user) { Factories.user }

  before do
    stub_connection current_user: user
  end

  it "rejects subscriptions without a job id" do
    subscribe

    expect(subscription).to be_rejected
  end

  it "rejects subscriptions for a job the user can't access" do
    other_job = Factories.job_record(user: Factories.user)

    subscribe(job_id: other_job.id)

    expect(subscription).to be_rejected
  end

  it "streams from the job-scoped resource channel for an accessible job" do
    job = Factories.job_record(user: user)

    subscribe(job_id: job.id)

    expect(subscription).to be_confirmed
    expect(subscription).to have_stream_from("job_resource:#{job.id}")
  end

  it "confirms for a repository member who isn't the job's owner" do
    job = Factories.job_record(user: user)
    member = Factories.user
    RepositoryMembership.create!(user: member, repository: job.repository, role: "read")

    stub_connection current_user: member
    subscribe(job_id: job.id)

    expect(subscription).to be_confirmed
    expect(subscription).to have_stream_from("job_resource:#{job.id}")
  end
end
