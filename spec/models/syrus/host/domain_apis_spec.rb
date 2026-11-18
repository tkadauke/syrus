require "rails_helper"

RSpec.describe "Syrus::Host domain APIs" do
  it "wraps domain records and their supported associations without exposing persistence" do
    user = Factories.user
    repository = Factories.repository(user:)
    job = Factories.job_with_run(user:, repository:)
    workflow = job.workflows.first

    facade = Syrus::Host::Job.find(job.id)

    expect(facade).to have_attributes(id: job.id, title: job.title, state: job.state)
    expect(facade.repository).to be_a(Syrus::Host::Repository)
    expect(facade.user).to be_a(Syrus::Host::User)
    expect(facade.workflows.map(&:id)).to include(workflow.id)
    expect(facade).not_to respond_to(:update!, :destroy!)
  end

  it "returns facades from access-scoped lookups" do
    user = Factories.user
    repository = Factories.repository(user:)
    job = Factories.job_record(user:, repository:)

    expect(Syrus::Host::Job.visible_to(user).map(&:id)).to include(job.id)
    expect(Syrus::Host::Repository.accessible_to(user).map(&:id)).to include(repository.id)
  end
end
