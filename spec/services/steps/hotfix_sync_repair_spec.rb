require "rails_helper"
require "tmpdir"

RSpec.describe Steps::HotfixSyncRepair do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, default_branch: "main") }
  let(:job) do
    Job.create!(
      user: user,
      repository: repository,
      kind: "direct",
      issue_number: nil,
      issue_title: "Sync main into develop"
    )
  end
  let(:workflow) do
    Workflows::HotfixSync.instantiate(
      job: job,
      artifacts: { "hotfix_sync_source_branch" => "main", "hotfix_sync_target_branch" => "develop" }
    )
  end
  let(:step) { workflow.steps.where(kind: "hotfix_sync_repair", loop_id: nil).first! }
  let(:run) { step.runs.first || step.runs.create!(job: job, trigger_kind: workflow.trigger_kind) }
  let(:handler) { described_class.new(run) }

  let(:resolution) do
    Skills::Resolution.new(
      source: :repo_override,
      path: ".syrus/skills/backport_release_hotfix/SKILL.md",
      klass: nil,
      definition: Skills::Definition.new(
        name: "backport_release_hotfix",
        description: "Resolve hotfix-sync conflicts",
        parameters: Skills::ParameterSchema.normalize([
          { "key" => "source_branch", "type" => "string", "required" => false },
          { "key" => "target_branch", "type" => "string", "required" => false }
        ]),
        instructions: "Reconcile {{source_branch}} into {{target_branch}} and resolve any conflicts."
      )
    )
  end

  around do |ex|
    Dir.mktmpdir("syrus-hotfix-sync-repair") do |dir|
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
    allow(DeliveryPolicy).to receive(:for).with(repository: repository).and_return(
      instance_double(DeliveryPolicy, hotfix_sync_repair_skill: "backport_release_hotfix")
    )
    allow(Skills).to receive(:for).and_return(resolution)
  end

  context "when the merge conflicted" do
    before { workflow.set_artifact!("hotfix_sync_assemble_result", "succeeded" => false, "reason" => "conflict") }

    describe "when the agent produces a diff" do
      before do
        allow(handler).to receive(:diff_against_default).and_return("diff --git a/foo.rb b/foo.rb\n+bar")
        allow(handler).to receive(:diff_against_sha).and_return("diff --git a/foo.rb b/foo.rb\n+bar")
      end

      it "resolves the configured repair skill and records provenance" do
        handler.call

        run.reload
        expect(run.skill_source).to eq("repo_override")
        expect(run.skill_resolved_path).to eq(".syrus/skills/backport_release_hotfix/SKILL.md")
        expect(run.agent_diff).to eq("diff --git a/foo.rb b/foo.rb\n+bar")
      end

      it "composes a prompt explaining the merge conflicted and renders the skill's instructions" do
        handler.call

        prompt = run.reload.prompt
        expect(prompt).to include("the deterministic merge attempt hit a conflict")
        expect(prompt).to include("Reconcile main into develop and resolve any conflicts.")
        expect(prompt).not_to include("{{source_branch}}")
      end
    end

    describe "when the agent produces no diff" do
      before { allow(handler).to receive(:diff_against_default).and_return("") }

      it "raises NoChangesProduced" do
        expect { handler.call }.to raise_error(Steps::Base::NoChangesProduced)
      end
    end
  end

  context "when reached as the retry_until loop's grader-failure repair (not a conflict)" do
    before do
      allow(handler).to receive(:diff_against_default).and_return("diff --git a/foo.rb b/foo.rb\n+bar")
      allow(handler).to receive(:diff_against_sha).and_return("diff --git a/foo.rb b/foo.rb\n+bar")
    end

    it "composes a prompt explaining the hotfix-sync grade phase failed" do
      handler.call

      expect(run.reload.prompt).to include("the hotfix-sync grade phase failed on the merged branch")
    end
  end

  context "when no repair skill is configured" do
    before do
      allow(DeliveryPolicy).to receive(:for).with(repository: repository).and_return(
        instance_double(DeliveryPolicy, hotfix_sync_repair_skill: nil)
      )
    end

    it "raises StepFailed instead of invoking the agent" do
      expect(handler).not_to receive(:run_agent)

      expect { handler.call }.to raise_error(Steps::Base::StepFailed, /no delivery.hotfix_sync.repair_skill configured/)
    end
  end

  context "when the configured repair skill does not resolve" do
    before { allow(Skills).to receive(:for).and_raise(Skills::NotFoundError, "not found") }

    it "raises StepFailed instead of invoking the agent" do
      expect(handler).not_to receive(:run_agent)

      expect { handler.call }.to raise_error(Steps::Base::StepFailed, /could not resolve repair skill/)
    end
  end
end
