require "rails_helper"
require Rails.root.join("db/migrate/20260730133058_add_external_pr_unique_index_to_jobs")

RSpec.describe AddExternalPrUniqueIndexToJobs, :ci_only do
  let(:migration) { described_class.new }
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:index_name) { "index_jobs_on_repository_id_and_external_pr_number_unique" }

  around do |example|
    migration.down
    example.run
  ensure
    migration.up
  end

  it "clears duplicate legacy external PR links before adding the unique index" do
    first = Factories.job_record(
      user: user,
      repository: repository,
      issue_number: 20,
      state: "closed",
      closure_reason: "external_pr_merged",
      finished_at: 2.days.ago
    )
    second = Factories.job_record(
      user: user,
      repository: repository,
      issue_number: 19,
      state: "closed",
      closure_reason: "external_pr_merged",
      finished_at: 2.days.ago
    )
    first.update_columns(external_pr_number: 21)
    second.update_columns(external_pr_number: 21)

    expect { migration.up }.not_to raise_error

    linked_jobs = Job.where(repository: repository, external_pr_number: 21)
    expect(linked_jobs.count).to eq(1)
    expect(Job.where(id: [ first.id, second.id ], external_pr_number: nil).count).to eq(1)
    expect(ActiveRecord::Base.connection.index_exists?(:jobs, [ :repository_id, :external_pr_number ], name: index_name)).to eq(true)
  end

  it "prefers an external_pr Job over a legacy issue Job for the retained link" do
    legacy = Factories.job_record(user: user, repository: repository, issue_number: 30)
    external = Job.create!(
      user: user,
      repository: repository,
      kind: "external_pr",
      state: "implemented",
      external_pr_number: 22
    )
    legacy.update_columns(external_pr_number: 22)

    migration.up

    expect(external.reload.external_pr_number).to eq(22)
    expect(legacy.reload.external_pr_number).to be_nil
  end
end
