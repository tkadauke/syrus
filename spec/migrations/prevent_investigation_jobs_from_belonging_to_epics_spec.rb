require "rails_helper"
require Rails.root.join("db/migrate/20261025171242_prevent_investigation_jobs_from_belonging_to_epics")

RSpec.describe PreventInvestigationJobsFromBelongingToEpics, :ci_only do
  let(:migration) { described_class.new }

  after { migration.up }

  it "detaches legacy investigation Jobs and clears their Epic title snapshot" do
    epic = Factories.epic(title: "Legacy Epic")
    job = Factories.job_record(user: epic.user, repository: epic.repository, epic: epic)

    migration.down
    job.update_columns(investigation: true)

    expect(job.reload).to have_attributes(epic_id: epic.id, epic_title: "Legacy Epic", investigation: true)

    migration.up

    expect(job.reload).to have_attributes(epic_id: nil, epic_title: nil, investigation: true)
  end
end
