require "rails_helper"

RSpec.describe Services::ConcurrentJobsContext do
  let(:repository) { Factories.repository }
  let(:job) do
    Factories.job(
      repository: repository,
      issue_number: 100,
      issue_title: "Current work",
      branch_name: "syrus/issue-100"
    )
  end
  let(:github_client) { instance_double(GithubClient) }

  before do
    allow(github_client).to receive(:changed_files_between).and_return([])
  end

  describe "#entries" do
    it "returns no entries when no other jobs are in flight on the repo" do
      context = described_class.new(job: job, github_client: github_client)

      expect(context.entries).to eq([])
      expect(context.to_prompt_section).to be_nil
      expect(github_client).not_to have_received(:changed_files_between)
    end

    it "includes another in-flight job and the files changed on its branch" do
      other = Factories.job(
        repository: repository,
        issue_number: 142,
        issue_title: "Fix login bug",
        branch_name: "syrus/issue-142"
      )
      other.latest_workflow.start!
      other.latest_workflow.save!

      allow(github_client).to receive(:changed_files_between)
        .with(repository.slug, repository.default_branch, "syrus/issue-142")
        .and_return([ "app/models/user.rb", "app/controllers/sessions_controller.rb" ])

      entry = described_class.new(job: job, github_client: github_client).entries.first

      expect(entry.job_id).to eq(other.id)
      expect(entry.issue_title).to eq("Fix login bug")
      expect(entry.files).to eq([ "app/models/user.rb", "app/controllers/sessions_controller.rb" ])
    end

    it "marks conflicts when another job touches the same files as the current job" do
      other = Factories.job(
        repository: repository,
        issue_number: 145,
        issue_title: "Add SSO",
        branch_name: "syrus/issue-145"
      )
      other.latest_workflow.start!
      other.latest_workflow.save!

      allow(github_client).to receive(:changed_files_between)
        .with(repository.slug, repository.default_branch, "syrus/issue-100")
        .and_return([ "app/controllers/sessions_controller.rb" ])
      allow(github_client).to receive(:changed_files_between)
        .with(repository.slug, repository.default_branch, "syrus/issue-145")
        .and_return([ "app/controllers/sessions_controller.rb", "config/routes.rb" ])

      context = described_class.new(job: job, github_client: github_client)

      expect(context.entries.first.conflicting_files).to eq([ "app/controllers/sessions_controller.rb" ])
      expect(context.to_prompt_section).to include("(conflicts on app/controllers/sessions_controller.rb)")
    end

    it "falls back to file-like paths in the issue text before a branch diff exists" do
      other = Factories.job(
        repository: repository,
        issue_number: 146,
        issue_title: "Update app/views/jobs/show.html.erb",
        issue_body: "The copy in app/helpers/jobs_helper.rb also needs attention."
      )
      other.latest_workflow.start!
      other.latest_workflow.save!

      entry = described_class.new(job: job, github_client: github_client).entries.first

      expect(entry.files).to eq([ "app/helpers/jobs_helper.rb", "app/views/jobs/show.html.erb" ])
    end
  end
end
