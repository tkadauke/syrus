require "rails_helper"
require Rails.root.join("db/migrate/20261108153718_clear_epic_from_main_grader_jobs")

RSpec.describe ClearEpicFromMainGraderJobs do
  it "clears only Epic metadata on main_grader Jobs" do
    user = Factories.user
    repo = Factories.repository(user: user)
    epic = Factories.epic(user: user, repository: repo)
    grader = repo.jobs.create!(user: user, kind: "main_grader")
    grader.update_columns(epic_id: epic.id, epic_title: epic.title, validity: "valid")
    ordinary = Factories.job_record(user: user, repository: repo, epic: epic, state: "queued")

    ActiveRecord::Migration.suppress_messages { described_class.new.up }

    grader.reload
    expect(grader.epic_id).to be_nil
    expect(grader.epic_title).to be_nil
    expect(grader.validity).to eq("valid")
    expect(ordinary.reload.epic_id).to eq(epic.id)
  end
end
