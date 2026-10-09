require "rails_helper"

RSpec.describe Job do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  describe "#investigation_launch?" do
    it "is true for a direct Job flagged investigation" do
      job = Job.new(kind: "direct", investigation: true)
      expect(job.investigation_launch?).to eq(true)
    end

    it "is false for a direct Job without the investigation flag" do
      job = Job.new(kind: "direct")
      expect(job.investigation_launch?).to eq(false)
    end

    it "is true for an issue Job filed as an investigation" do
      job = Job.new(kind: "issue", investigation: true)
      expect(job.investigation_launch?).to eq(true)
    end

    it "is true for a cron Job filed as an investigation" do
      job = Job.new(kind: "cron", investigation: true)
      expect(job.investigation_launch?).to eq(true)
    end

    it "is false for an issue Job without the investigation flag" do
      job = Job.new(kind: "issue")
      expect(job.investigation_launch?).to eq(false)
    end
  end

  describe "validations" do
    it "allows investigation on an issue Job, so a labelled issue can be filed as one" do
      job = Job.new(user: user, repository: repository, kind: "issue", issue_number: 1, investigation: true)
      job.valid?
      expect(job.errors[:investigation]).to be_empty
    end

    it "rejects investigation on a kind that is not investigable" do
      job = Job.new(user: user, repository: repository, kind: "main_grader", investigation: true)
      expect(job).not_to be_valid
      expect(job.errors[:investigation]).to include("requires an investigable Job kind")
    end

    it "allows investigation on a direct Job" do
      job = Job.new(user: user, repository: repository, kind: "direct", issue_number: nil, investigation: true)
      job.valid?
      expect(job.errors[:investigation]).to be_empty
    end

    it "allows investigation on a cron Job" do
      job = Job.new(user: user, repository: repository, kind: "cron", issue_number: nil, investigation: true)
      job.valid?
      expect(job.errors[:investigation]).to be_empty
    end

    it "allows investigation on a briefing generation Job without changing launch dispatch" do
      PluginRecord.find_or_create_by!(name: "operator_briefing").update!(enabled: true, disableable: true)
      job = Job.new(user: user, repository: repository, kind: "briefing_generate", issue_number: nil, investigation: true)

      job.valid?

      expect(job.errors[:investigation]).to be_empty
      expect(job.investigation_launch?).to eq(false)
    end

    it "rejects investigation combined with a skill_name" do
      job = Job.new(user: user, repository: repository, kind: "direct", issue_number: nil, investigation: true, skill_name: "investigate")
      expect(job).not_to be_valid
      expect(job.errors[:investigation]).to include("cannot be combined with skill_name")
    end
  end

  describe "#create_initial_run" do
    it "dispatches Workflows::Investigation instead of Workflows::Initial for an investigation launch" do
      job = Job.create!(
        user: user,
        repository: repository,
        kind: "direct",
        issue_number: nil,
        issue_title: "Investigation: what's slow about the dashboard?",
        issue_body: "Figure out why /dashboard feels slow.",
        investigation: true
      )

      job.advance_after_triage! if job.may_advance_after_triage?

      workflow = job.reload.workflows.last
      expect(workflow.trigger_kind).to eq("investigation")
      expect(workflow.work_unit).to be_present
    end

    it "does not seed the first run's prompt from Prompts::DirectJob for an investigation launch" do
      job = Job.create!(
        user: user,
        repository: repository,
        kind: "direct",
        issue_number: nil,
        issue_title: "Investigation: what's slow?",
        issue_body: "Figure out why /dashboard feels slow.",
        investigation: true
      )

      job.advance_after_triage! if job.may_advance_after_triage?

      first_run = job.reload.workflows.last.first_step.runs.first
      expect(first_run.prompt.to_s).to be_blank
    end

    it "still dispatches Workflows::Initial for an ordinary direct Job" do
      job = Job.create!(
        user: user,
        repository: repository,
        kind: "direct",
        issue_number: nil,
        issue_title: "Free-form job",
        issue_body: "Do the thing."
      )

      job.advance_after_triage! if job.may_advance_after_triage?

      expect(job.reload.workflows.last.trigger_kind).to eq("initial")
    end
  end
end
