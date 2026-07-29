require "rails_helper"

RSpec.describe Prompts::EpicContext do
  let(:epic) do
    instance_double(
      Epic,
      slug: "EPIC-70",
      title: "Syrus CLI and test planning",
      description: "Build the Go CLI and the Rails-side test planning step.",
      reconciliation_job_id: nil
    )
  end

  it "renders the Epic title, description, and scope guard" do
    out = described_class.new(epic: epic).to_s

    expect(out).to include("EPIC-70: Syrus CLI and test planning")
    expect(out).to include("Build the Go CLI and the Rails-side test planning step.")
    expect(out).to include("Do not implement the entire Epic")
    expect(out).to include("Implement only the Job described above")
  end

  it "renders the scope guard even when the Epic has no description" do
    allow(epic).to receive(:description).and_return(nil)

    out = described_class.new(epic: epic).to_s

    expect(out).to include("EPIC-70: Syrus CLI and test planning")
    expect(out).to include("Do not implement sibling Jobs")
    expect(out).not_to include("Epic description:")
  end

  it "is blank without an Epic" do
    expect(described_class.new(epic: nil).to_s).to eq("")
  end

  it "truncates long descriptions without splitting UTF-8" do
    description = "#{'a' * Prompts::EpicContext::MAX_DESCRIPTION_BYTES}é"
    allow(epic).to receive(:description).and_return(description)

    out = described_class.new(epic: epic).to_s

    expect(out).to be_valid_encoding
    expect(out).to include("[Epic description truncated after #{Prompts::EpicContext::MAX_DESCRIPTION_BYTES} bytes.]")
  end

  it "omits the approved siblings section when no job is provided" do
    out = described_class.new(epic: epic).to_s

    expect(out).not_to include("Approved sibling Jobs")
    expect(out).not_to include("changes are already in your working directory")
  end

  describe "approved sibling Jobs section" do
    let(:u) { Factories.user }
    let(:repo) { Factories.repository(user: u) }
    let(:epic_record) { Factories.epic(user: u, repository: repo) }
    let(:current_job) { Factories.job_record(user: u, repository: repo, epic: epic_record, state: "running") }

    it "lists approved siblings" do
      sibling = Factories.job_record(user: u, repository: repo, epic: epic_record, state: "approved", issue_title: "Add search")

      out = described_class.new(epic: epic_record, job: current_job).to_s

      expect(out).to include("#{sibling.slug}: Add search")
      expect(out).to include("## Approved sibling Jobs")
      expect(out).to include("These sibling Jobs have been approved and their changes are already in your working directory")
    end

    it "lists landing siblings" do
      sibling = Factories.job_record(user: u, repository: repo, epic: epic_record, state: "landing", issue_title: "Fix login")

      out = described_class.new(epic: epic_record, job: current_job).to_s

      expect(out).to include("#{sibling.slug}: Fix login")
    end

    it "omits the section when no siblings are approved or landing" do
      Factories.job_record(user: u, repository: repo, epic: epic_record, state: "running", issue_title: "In progress")

      out = described_class.new(epic: epic_record, job: current_job).to_s

      expect(out).not_to include("Approved sibling Jobs")
      expect(out).not_to include("changes are already in your working directory")
    end

    it "excludes the current Job from the siblings list" do
      current_job.update_columns(state: "approved", issue_title: "Current work")

      out = described_class.new(epic: epic_record, job: current_job).to_s

      expect(out).not_to include(current_job.slug)
    end

    it "excludes the reconciliation Job from the siblings list" do
      recon_job = Factories.job_record(user: u, repository: repo, epic: epic_record, state: "approved", issue_title: "Reconcile")
      epic_record.update_columns(reconciliation_job_id: recon_job.id)

      out = described_class.new(epic: epic_record, job: current_job).to_s

      expect(out).not_to include(recon_job.slug)
    end

    it "excludes both the current Job and the reconciliation Job when both are approved" do
      recon_job = Factories.job_record(user: u, repository: repo, epic: epic_record, state: "approved", issue_title: "Reconcile")
      other_sibling = Factories.job_record(user: u, repository: repo, epic: epic_record, state: "approved", issue_title: "Add feature")
      epic_record.update_columns(reconciliation_job_id: recon_job.id)
      current_job.update_columns(state: "approved", issue_title: "Current work")

      out = described_class.new(epic: epic_record, job: current_job).to_s

      expect(out).not_to include(recon_job.slug)
      expect(out).not_to include(current_job.slug)
      expect(out).to include(other_sibling.slug)
    end
  end
end
