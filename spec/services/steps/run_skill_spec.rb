require "rails_helper"
require "tmpdir"

RSpec.describe Steps::RunSkill do
  let(:job) do
    Factories.job(
      kind: "direct",
      issue_number: nil,
      issue_title: "Skill: investigate",
      issue_body: "Investigate: What does the widget do?",
      skill_name: "investigate",
      skill_args: { "question" => "What does the widget do?" }
    )
  end
  let(:workflow) { job.workflows.last }
  let(:step)     { workflow.steps.find_by(kind: "run_skill") }
  let(:run)      do
    step.runs.first || step.runs.create!(job: job, trigger_kind: workflow.trigger_kind)
  end
  let(:handler)  { described_class.new(run) }

  around do |ex|
    Dir.mktmpdir("syrus-run-skill") do |dir|
      @ws_path = Pathname.new(dir)
      ex.run
    end
  end

  before do
    fake_ws = instance_double(WorkflowWorkspace, setup: nil, path: @ws_path)
    allow(handler).to receive(:workspace).and_return(fake_ws)
    allow(handler).to receive(:run_agent)
    allow(handler).to receive(:commit_agent_changes)
    allow(handler).to receive(:assert_branch_history_intact!)
    allow(handler).to receive(:head_sha).and_return("abc123")
  end

  it "dispatches into the skill trigger_kind's prepare → run_skill → retry_until(run_skill → graders) → summarize → pr_open chain" do
    expect(workflow.trigger_kind).to eq("skill")
    expect(workflow.steps.order(:position).pluck(:kind)).to eq(
      %w[prepare run_skill grader_fanout grader_collect summarize pr_open]
    )
  end

  describe "when the agent produces a diff" do
    before do
      allow(handler).to receive(:diff_against_default).and_return("diff --git a/foo.rb b/foo.rb\n+bar")
      allow(handler).to receive(:diff_against_sha).and_return("diff --git a/foo.rb b/foo.rb\n+bar")
    end

    it "resolves the built-in skill and records skill_source/resolved_class provenance on the Run" do
      handler.call

      run.reload
      expect(run.agent_diff).to eq("diff --git a/foo.rb b/foo.rb\n+bar")
      expect(run.skill_source).to eq("built_in")
      expect(run.skill_resolved_path).to be_nil
      expect(run.skill_resolved_class).to eq("Skills::Investigate")
    end

    it "renders the skill's instructions with the supplied args substituted into the prompt" do
      handler.call

      prompt = run.reload.prompt
      expect(prompt).to include("Skill: investigate")
      expect(prompt).to include("Question: What does the widget do?")
      expect(prompt).not_to include("{{question}}")
    end

    it "includes the phased-execution note telling the agent not to call submit_summary" do
      handler.call

      expect(run.reload.prompt).to include("Phased execution note: you're running the **run_skill** step")
      expect(run.reload.prompt).to include("DO NOT")
    end
  end

  describe "when the agent produces no diff" do
    before do
      allow(handler).to receive(:diff_against_default).and_return("")
    end

    it "raises NoChangesProduced but still records provenance before raising" do
      expect { handler.call }.to raise_error(Steps::Base::NoChangesProduced)

      expect(run.reload.skill_source).to eq("built_in")
      expect(run.reload.skill_resolved_class).to eq("Skills::Investigate")
    end
  end

  context "when a repo-local skill shadows the built-in one" do
    let(:shadow_resolution) do
      Skills::Resolution.new(
        source: :repo_override,
        path: ".syrus/skills/investigate/SKILL.md",
        klass: nil,
        definition: Skills::Definition.new(
          name: "investigate",
          description: "Repo-local override",
          parameters: Skills::ParameterSchema.normalize([ { "key" => "question", "type" => "string", "required" => true } ]),
          instructions: "Repo override answer for: {{question}}"
        )
      )
    end

    before do
      allow(Skills).to receive(:for).and_return(shadow_resolution)
      allow(handler).to receive(:diff_against_default).and_return("diff --git a/foo.rb b/foo.rb\n+bar")
      allow(handler).to receive(:diff_against_sha).and_return("diff --git a/foo.rb b/foo.rb\n+bar")
    end

    it "records skill_source=repo_override with the resolved path instead of a class" do
      handler.call

      run.reload
      expect(run.skill_source).to eq("repo_override")
      expect(run.skill_resolved_path).to eq(".syrus/skills/investigate/SKILL.md")
      expect(run.skill_resolved_class).to be_nil
      expect(run.prompt).to include("Repo override answer for: What does the widget do?")
    end
  end

  context "when the skill args fail parameter validation" do
    let(:job) do
      Factories.job(
        kind: "direct",
        issue_number: nil,
        skill_name: "investigate",
        skill_args: {}
      )
    end

    it "raises StepFailed instead of invoking the agent" do
      expect(handler).not_to receive(:run_agent)

      expect { handler.call }.to raise_error(Steps::Base::StepFailed, /args invalid/)
    end
  end

  context "when the skill name does not resolve" do
    let(:job) do
      Factories.job(
        kind: "direct",
        issue_number: nil,
        skill_name: "does-not-exist",
        skill_args: {}
      )
    end

    it "raises StepFailed instead of invoking the agent" do
      expect(handler).not_to receive(:run_agent)

      expect { handler.call }.to raise_error(Steps::Base::StepFailed, /could not resolve skill/)
    end
  end
end
