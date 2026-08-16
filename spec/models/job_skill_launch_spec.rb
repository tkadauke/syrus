require "rails_helper"

RSpec.describe Job do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  describe "#skill_launch?" do
    it "is true for a direct Job carrying a skill_name" do
      job = Job.new(kind: "direct", skill_name: "investigate")
      expect(job.skill_launch?).to eq(true)
    end

    it "is false for a direct Job without a skill_name" do
      job = Job.new(kind: "direct")
      expect(job.skill_launch?).to eq(false)
    end

    it "is false for a non-direct Job even if skill_name is somehow set" do
      job = Job.new(kind: "issue")
      job.skill_name = nil
      expect(job.skill_launch?).to eq(false)
    end
  end

  describe "validations" do
    it "rejects a skill_name that doesn't match the Skills name pattern" do
      job = Job.new(user: user, repository: repository, kind: "direct", issue_number: nil, skill_name: "Not Valid!")
      expect(job).not_to be_valid
      expect(job.errors[:skill_name]).to be_present
    end

    it "rejects a skill_name on a non-direct Job" do
      job = Job.new(user: user, repository: repository, kind: "issue", issue_number: 1, skill_name: "investigate")
      expect(job).not_to be_valid
      expect(job.errors[:skill_name]).to include("requires kind=direct")
    end

    it "allows a valid skill_name on a direct Job" do
      job = Job.new(user: user, repository: repository, kind: "direct", issue_number: nil, skill_name: "investigate")
      job.valid?
      expect(job.errors[:skill_name]).to be_empty
    end
  end

  describe "#create_initial_run" do
    it "dispatches Workflows::Skill instead of Workflows::Initial for a skill launch" do
      job = Job.create!(
        user: user,
        repository: repository,
        kind: "direct",
        issue_number: nil,
        issue_title: "Skill: investigate",
        skill_name: "investigate",
        skill_args: { "question" => "What does the widget do?" }
      )

      job.advance_after_triage! if job.may_advance_after_triage?

      workflow = job.reload.workflows.last
      expect(workflow.trigger_kind).to eq("skill")
      expect(workflow.artifact("skill_name")).to eq("investigate")
      expect(workflow.artifact("skill_args")).to eq({ "question" => "What does the widget do?" })
    end

    it "does not seed the run prompt from Prompts::DirectJob for a skill launch" do
      job = Job.create!(
        user: user,
        repository: repository,
        kind: "direct",
        issue_number: nil,
        issue_title: "Skill: investigate",
        issue_body: "this free-form text must not become the run_skill prompt",
        skill_name: "investigate",
        skill_args: { "question" => "What does the widget do?" }
      )

      job.advance_after_triage! if job.may_advance_after_triage?

      first_run = job.reload.workflows.last.first_step.runs.first
      expect(first_run.prompt.to_s).not_to include("this free-form text must not become the run_skill prompt")
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
