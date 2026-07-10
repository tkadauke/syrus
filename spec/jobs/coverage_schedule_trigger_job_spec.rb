require "rails_helper"

RSpec.describe CoverageScheduleTriggerJob do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:source_job) { Factories.job(repository: repository) }
  let(:workflow) { source_job.workflows.last }

  let(:plan) do
    SyrusYml::CoverageConfig.new(
      sources: [],
      threshold: nil,
      on_miss: "schedule",
      hitmap_ttl_days: 7,
      pr_comment: false,
      schedule_prompt: "Add tests to improve coverage."
    )
  end

  before do
    workflow  # force eager creation of source_job and workflow before each example
    allow(RepoCoveragePlan).to receive(:for).and_return(plan)
  end

  it "creates a direct Job with the configured prompt and title" do
    expect {
      described_class.perform_now(workflow.id)
    }.to change(Job, :count).by(1)

    created = Job.where(kind: "direct", repository: repository).last
    expect(created.issue_title).to eq("Improve test coverage")
    expect(created.issue_body).to eq("Add tests to improve coverage.")
    expect(created.user).to eq(user)
  end

  it "tags the created Job with coverage-improvement" do
    described_class.perform_now(workflow.id)

    created = Job.where(kind: "direct", repository: repository).last
    expect(created.tags.pluck(:name)).to include("coverage-improvement")
  end

  context "idempotency" do
    it "does not create a second Job within 24 hours when the first is still open" do
      described_class.perform_now(workflow.id)

      expect {
        described_class.perform_now(workflow.id)
      }.not_to change(Job, :count)
    end

    it "creates a new Job after the existing coverage-improvement Job closes" do
      described_class.perform_now(workflow.id)
      Job.where(kind: "direct", repository: repository).last.update_columns(state: "closed", closure_reason: "no_changes", finished_at: Time.current)

      expect {
        described_class.perform_now(workflow.id)
      }.to change(Job, :count).by(1)
    end

    it "creates a new Job when the previous coverage-improvement Job is older than 24 hours" do
      described_class.perform_now(workflow.id)
      Job.where(kind: "direct", repository: repository).last.update_columns(created_at: 25.hours.ago)

      expect {
        described_class.perform_now(workflow.id)
      }.to change(Job, :count).by(1)
    end
  end

  context "when schedule_prompt is blank" do
    let(:plan) do
      SyrusYml::CoverageConfig.new(
        sources: [],
        threshold: nil,
        on_miss: "schedule",
        hitmap_ttl_days: 7,
        pr_comment: false,
        schedule_prompt: nil
      )
    end

    it "does nothing" do
      expect {
        described_class.perform_now(workflow.id)
      }.not_to change(Job, :count)
    end
  end

  context "when on_miss is not schedule" do
    let(:plan) do
      SyrusYml::CoverageConfig.new(
        sources: [],
        threshold: nil,
        on_miss: "warn",
        hitmap_ttl_days: 7,
        pr_comment: false,
        schedule_prompt: "Add tests."
      )
    end

    it "does nothing" do
      expect {
        described_class.perform_now(workflow.id)
      }.not_to change(Job, :count)
    end
  end

  context "when no coverage plan is found" do
    before { allow(RepoCoveragePlan).to receive(:for).and_return(nil) }

    it "does nothing" do
      expect {
        described_class.perform_now(workflow.id)
      }.not_to change(Job, :count)
    end
  end

  context "when the workflow does not exist" do
    it "does nothing without raising" do
      expect {
        described_class.perform_now(0)
      }.not_to raise_error
    end
  end
end
