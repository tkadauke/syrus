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

  it "resolves prefixed job references to the canonical job stream" do
    job = Factories.job_record(user: user)

    subscribe(job_id: "JOB-#{job.id}")

    expect(subscription).to be_confirmed
    expect(subscription).to have_stream_from("job_resource:#{job.id}")
  end

  it "resolves human-readable slugs to the canonical job stream" do
    job = Factories.job_record(user: user, slug: "canonical-live-events")

    subscribe(job_id: job.slug)

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

  # Visibility was checked only on subscribe, and the stream is shared by every
  # subscriber of the Job, so a user who lost access (membership removed,
  # visibility narrowed) kept receiving the Job's Workflow, Step and Run patches
  # until the tab reconnected. Each delivery rechecks the same Job.visible_to
  # the subscription used (cached briefly), and a subscriber who can no longer
  # see the Job stops receiving it (NY20, formal/SyrusModel/ScopedDelivery.lean).
  describe "delivery after access changes" do
    let(:job) { Factories.job_record(user: user) }
    let(:member) { Factories.user }
    let!(:membership) { RepositoryMembership.create!(user: member, repository: job.repository, role: "read") }
    let(:message) { { "type" => "step.updated", "resource" => "step", "id" => 1, "job_id" => job.id } }

    before do
      stub_connection current_user: member
      subscribe(job_id: job.id)
    end

    it "transmits while the subscriber can still see the Job" do
      subscription.send(:deliver, message)

      expect(transmissions.last).to eq(message)
    end

    it "stops transmitting, and stops the stream, once the subscriber loses access" do
      membership.destroy!
      travel(JobChannel::VISIBILITY_RECHECK_INTERVAL + 1.second)

      subscription.send(:deliver, message)

      expect(transmissions).to be_empty
      expect(subscription).not_to have_streams
    end

    it "rechecks at most once per interval" do
      allow(Job).to receive(:visible_to).and_call_original
      subscription.send(:deliver, message)
      subscription.send(:deliver, message)

      expect(Job).not_to have_received(:visible_to)
    end
  end
end
