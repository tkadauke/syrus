require "rails_helper"

RSpec.describe Steps::MergeTrainRebase do
  # Regression: the clean-rebase grade carry-forward compared the fingerprint
  # Steps::GraderFanout had written against one built a different way here, so
  # the two digests never matched. In production that produced 79 declines and
  # zero carries, every one reported as "required grader configuration
  # changed" while the configuration was in fact identical -- so a clean
  # rebase of an already-green assembly regraded from scratch every time.
  #
  # The fingerprint must be built from TargetGraph::GradePlan, which spans
  # every project's graders, not from RepoGradePlan, which covers only the
  # root .syrus.yml.
  describe "#current_landing_grader_fingerprint" do
    let(:path) { Rails.root }

    def writer_fingerprint(trigger_kind:, iteration:)
      graph = TargetGraph::Compiler.compile(path)
      plan = LandingGraderPlan.effective(
        TargetGraph::GradePlan.for(workspace_path: path, graph: graph),
        trigger_kind: trigger_kind,
        iteration: iteration
      )
      GraderConclusionCache.fingerprint_for_plan(plan, target_graph: graph)
    end

    def reader_fingerprint
      step = described_class.allocate
      workspace = instance_double("WorkflowWorkspace", path: path)
      allow(step).to receive(:workspace).and_return(workspace)
      step.send(:current_landing_grader_fingerprint)
    end

    it "matches the fingerprint a merge-train grader fanout writes" do
      expect(reader_fingerprint).to eq(writer_fingerprint(trigger_kind: "merge_train", iteration: 1))
    end

    it "spans every project's graders, not just the root config" do
      graph = TargetGraph::Compiler.compile(path)
      root_only = LandingGraderPlan.landing(RepoGradePlan.for(path))
      graph_wide = LandingGraderPlan.landing(TargetGraph::GradePlan.for(workspace_path: path, graph: graph))

      expect(graph_wide.graders.size).to be > root_only.graders.size
      expect(reader_fingerprint).not_to eq(
        GraderConclusionCache.fingerprint_for_plan(root_only, target_graph: graph)
      )
    end
  end
end
