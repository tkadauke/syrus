require "rails_helper"

RSpec.describe SyrusCoverage::Subscribers do
  it "subscribes to job.closed" do
    expect(described_class.subscriptions).to eq("job.closed" => :on_job_closed)
  end

  it "purges the hit maps of every workflow of the closed Job and leaves other Jobs alone" do
    job = Factories.job
    other = Factories.job
    SyrusCoverage::HitMap.store!(job.workflows.first, { "a.rb" => { "1" => 1 } })
    SyrusCoverage::HitMap.store!(other.workflows.first, { "a.rb" => { "1" => 1 } })

    described_class.on_job_closed(job_id: job.id)

    expect(SyrusCoverage::HitMap.attached_for?(job.workflows.first)).to be(false)
    expect(SyrusCoverage::HitMap.attached_for?(other.workflows.first)).to be(true)
  end

  it "is enqueued for delivery when the host publishes job.closed" do
    job = Factories.job

    expect { Syrus::Events.publish("job.closed", job_id: job.id) }
      .to have_enqueued_job(DomainEventJob).with("job.closed", hash_including("job_id" => job.id), "SyrusCoverage::Subscribers")
  end
end
