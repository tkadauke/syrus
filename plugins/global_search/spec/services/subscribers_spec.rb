require "rails_helper"

RSpec.describe GlobalSearch::Subscribers do
  include ActiveJob::TestHelper

  def event(name, payload)
    Syrus::DomainEvent.new(name: name, payload: payload.stringify_keys)
  end

  it "indexes a Job when core announces it changed" do
    expect { described_class.on_job_upserted(event("job.upserted", job_id: 7)) }
      .to have_enqueued_job(IndexJobSearchJob).with(7)
  end

  it "indexes an Epic when core announces it changed" do
    expect { described_class.on_epic_upserted(event("epic.upserted", epic_id: 3)) }
      .to have_enqueued_job(IndexEpicSearchJob).with(3)
  end

  it "reaches the index through a published event rather than a call from core" do
    job = Factories.job

    expect { job.publish_upserted! }
      .to have_enqueued_job(DomainEventJob).with("job.upserted", anything, described_class.to_s)
  end

  # These ran as core Job/Epic specs before search became a plugin. They belong
  # here now, and they run end-to-end -- create the record, let the published
  # event be delivered, and check the index job actually lands on `indexing`.
  it "indexes a Job created in core, through the event", :ci_only do
    repo = Factories.repository

    expect {
      perform_enqueued_jobs(only: DomainEventJob) do
        Factories.job_record(user: repo.user, repository: repo, issue_title: "Search me")
      end
    }.to have_enqueued_job(IndexJobSearchJob).with(kind_of(Integer)).on_queue("indexing")
  end

  it "indexes a Job updated in core, through the event", :ci_only do
    job = Factories.job_record(issue_title: "Search me")
    clear_enqueued_jobs

    expect {
      perform_enqueued_jobs(only: DomainEventJob) do
        job.update!(issue_title: "Search me again")
      end
    }.to have_enqueued_job(IndexJobSearchJob).with(job.id).on_queue("indexing")
  end

  it "indexes an Epic created in core, through the event", :ci_only do
    repository = Factories.repository

    expect {
      perform_enqueued_jobs(only: DomainEventJob) do
        Factories.epic(user: repository.user, repository: repository, title: "Search me")
      end
    }.to have_enqueued_job(IndexEpicSearchJob).with(kind_of(Integer)).on_queue("indexing")
  end

  it "indexes an Epic updated in core, through the event", :ci_only do
    epic = Factories.epic(title: "Search me")
    clear_enqueued_jobs

    expect {
      perform_enqueued_jobs(only: DomainEventJob) do
        epic.update!(title: "Search me again")
      end
    }.to have_enqueued_job(IndexEpicSearchJob).with(epic.id).on_queue("indexing")
  end

  it "subscribes to the events it handles" do
    expect(described_class.subscriptions.keys).to contain_exactly("job.upserted", "epic.upserted")
  end
end
