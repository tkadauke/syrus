require "rails_helper"

RSpec.describe MainConcernReport do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job(repository: repository) }
  let(:run) { job.initial_run }
  let(:workflow) { run.workflow }

  describe "associations" do
    it "belongs to repository" do
      report = MainConcernReport.new(
        repository: repository, job: job, workflow: workflow, run: run,
        reason: "Tests in unrelated files are failing"
      )
      expect(report.repository).to eq(repository)
    end
  end

  describe "validations" do
    it "is invalid without reason" do
      report = MainConcernReport.new(
        repository: repository, job: job, workflow: workflow, run: run
      )
      expect(report).not_to be_valid
      expect(report.errors[:reason]).to be_present
    end

    it "is valid with required attributes" do
      report = MainConcernReport.new(
        repository: repository, job: job, workflow: workflow, run: run,
        reason: "spec/unrelated_spec.rb failures predate my changes"
      )
      expect(report).to be_valid
    end

    it "stores failing_tests as a json array" do
      report = MainConcernReport.create!(
        repository: repository, job: job, workflow: workflow, run: run,
        reason: "unrelated failures",
        failing_tests: [ "spec/foo_spec.rb", "spec/bar_spec.rb" ]
      )
      expect(report.reload.failing_tests).to eq([ "spec/foo_spec.rb", "spec/bar_spec.rb" ])
    end

    it "allows nil failing_tests" do
      report = MainConcernReport.create!(
        repository: repository, job: job, workflow: workflow, run: run,
        reason: "unrelated failures"
      )
      expect(report.reload.failing_tests).to be_nil
    end
  end

  describe ".for_repository_since" do
    it "returns reports for the given repository within the window" do
      report = MainConcernReport.create!(
        repository: repository, job: job, workflow: workflow, run: run,
        reason: "recent failure"
      )
      expect(MainConcernReport.for_repository_since(repository, 1.hour.ago)).to include(report)
    end

    it "excludes reports older than the window" do
      report = MainConcernReport.create!(
        repository: repository, job: job, workflow: workflow, run: run,
        reason: "old failure",
        created_at: 2.hours.ago
      )
      expect(MainConcernReport.for_repository_since(repository, 1.hour.ago)).not_to include(report)
    end

    it "excludes reports for other repositories" do
      other_repo = Factories.repository(user: user)
      other_job = Factories.job(repository: other_repo)
      MainConcernReport.create!(
        repository: other_repo, job: other_job,
        workflow: other_job.latest_workflow, run: other_job.initial_run,
        reason: "other repo failure"
      )
      expect(MainConcernReport.for_repository_since(repository, 1.hour.ago)).to be_empty
    end
  end
end
