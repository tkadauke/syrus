require "rails_helper"

RSpec.describe LandingValidationManifest, :real_landing_validation_gate do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_record(user: user, repository: repository, state: "approved", pr_number: 42) }
  let(:sha) { "a" * 40 }

  def target(name, outcome: "passed", required: true, evidence: true, source_sha: sha, command: "c-#{name}", env: "e-#{name}", source: "ran", reason: "grader_passed")
    {
      "name" => name, "target_label" => "//:grade/#{name}", "required" => required,
      "outcome" => outcome, "reason" => reason, "source" => source, "source_sha" => source_sha,
      "command_fingerprint" => command, "environment_fingerprint" => env, "has_evidence" => evidence
    }
  end

  def manifest(targets: [ target("rspec") ], head_sha: sha, **extra)
    { "version" => 1, "head_sha" => head_sha, "tree_sha" => "tree1", "targets" => targets }.merge(extra)
  end

  def store(manifest, trigger_kind: "auto_merge")
    Workflow.create!(job: job, trigger_kind: trigger_kind).tap do |workflow|
      workflow.set_artifact!(described_class::ARTIFACT_KEY, manifest)
    end
  end

  describe ".verify" do
    it "accepts conclusive green required results bound to the SHA (ordinary PR)" do
      verdict = described_class.verify(manifest, expected_sha: sha)
      expect(verdict).to be_ok
      expect(verdict.binding).to eq("exact_head")
    end

    it "blocks when there is no manifest" do
      verdict = described_class.verify(nil, expected_sha: sha)
      expect(verdict.blockers.map(&:code)).to eq([ "manifest_missing" ])
    end

    it "blocks a manifest recorded for another SHA (stale evidence)" do
      verdict = described_class.verify(manifest(head_sha: "b" * 40), expected_sha: sha)
      expect(verdict.blockers.map(&:code)).to include("sha_mismatch")
      expect(verdict.reason).to include("bbbbbbb")
    end

    it "blocks a required target that ran against a different snapshot SHA" do
      verdict = described_class.verify(manifest(targets: [ target("rspec", source_sha: "c" * 40) ]), expected_sha: sha)
      expect(verdict.blockers.map(&:code)).to eq([ "sha_mismatch" ])
    end

    it "blocks inconclusive required results with an actionable reason" do
      verdict = described_class.verify(manifest(targets: [ target("rspec", outcome: "inconclusive", reason: "missing_exit_status") ]), expected_sha: sha)
      expect(verdict.blockers.map(&:code)).to eq([ "required_result_inconclusive" ])
      expect(verdict.reason).to include("missing_exit_status").and include("re-run")
    end

    it "reports infrastructure-exhausted results as infrastructure, not a code verdict" do
      verdict = described_class.verify(manifest(targets: [ target("rspec", outcome: "infrastructure_failed", reason: "worker_died") ]), expected_sha: sha)
      expect(verdict.blockers.map(&:code)).to eq([ "required_result_infrastructure_failed" ])
      expect(verdict.reason).to include("not a code verdict")
    end

    it "blocks a pass without command/environment evidence" do
      verdict = described_class.verify(manifest(targets: [ target("rspec", evidence: false) ]), expected_sha: sha)
      expect(verdict.blockers.map(&:code)).to eq([ "required_evidence_missing" ])
    end

    it "blocks a manifest with no required results" do
      verdict = described_class.verify(manifest(targets: [ target("lint", required: false) ]), expected_sha: sha)
      expect(verdict.blockers.map(&:code)).to eq([ "required_result_missing" ])
    end

    it "ignores non-required failures" do
      verdict = described_class.verify(manifest(targets: [ target("rspec"), target("lint", required: false, outcome: "test_failed") ]), expected_sha: sha)
      expect(verdict).to be_ok
    end

    it "accepts reused target-health evidence that carries fingerprints" do
      verdict = described_class.verify(manifest(targets: [ target("rspec", source: "target_health", reason: "target_health") ]), expected_sha: sha)
      expect(verdict).to be_ok
    end
  end

  describe ".evidence_for (merge-train integration SHAs and rebases)" do
    it "finds the manifest recorded for the exact integration SHA" do
      store(manifest, trigger_kind: "merge_train")
      expect(described_class.evidence_for(job: job, sha: sha)).to be_ok
    end

    it "blocks after a rebase moved the SHA" do
      store(manifest)
      verdict = described_class.evidence_for(job: job, sha: "d" * 40, tree_sha: "other-tree")
      expect(verdict).not_to be_ok
      expect(verdict.blockers.first.code).to eq("sha_mismatch")
    end

    it "accepts a rebased SHA only when the tree is identical" do
      store(manifest)
      verdict = described_class.evidence_for(job: job, sha: "d" * 40, tree_sha: "tree1")
      expect(verdict).to be_ok
      expect(verdict.binding).to eq("same_tree")
    end

    it "blocks when the job has no manifest at all" do
      expect(described_class.evidence_for(job: job, sha: sha).blockers.first.code).to eq("manifest_missing")
    end

    it "accepts an explicit clean-rebase carry-forward bound to the new SHA" do
      workflow = store(manifest)
      new_sha = "e" * 40
      described_class.carry_forward!(workflow: workflow, manifest: manifest, head_sha: new_sha, tree_sha: "tree2", base_sha: "f" * 40, base_ref: "main")
      verdict = described_class.evidence_for(job: job, sha: new_sha, tree_sha: "tree2")
      expect(verdict).to be_ok
      expect(verdict.binding).to eq("clean_rebase_carry_forward")
      expect(verdict.manifest["carried_from_sha"]).to eq(sha)
    end
  end

  describe ".gate" do
    it "records the gate payload with blockers and post-merge delta for diagnostics" do
      ci_set = { "targets" => [ { "name" => "e2e", "target_label" => "//:grade/e2e", "affected" => true } ] }
      workflow = store(manifest("ci_phase_target_set" => ci_set))
      described_class.gate(job: job, sha: sha, workflow: workflow)
      gate = workflow.reload.artifact("landing_parity_gate")
      expect(gate).to include("ok" => true, "sha" => sha)
      expect(gate["post_merge_delta"]).to eq([ { "target_label" => "//:grade/e2e", "name" => "e2e", "reason" => "ci_phase_target_not_validated_pre_merge" } ])
    end
  end

  describe ".compare_with_main" do
    let(:selections) do
      [ { "name" => "rspec", "target_label" => "//:grade/rspec", "affected" => true, "target_fingerprints" => { "command_fingerprint" => "c-rspec", "environment_fingerprint" => "e-rspec" } } ]
    end

    it "attributes selected targets to matching pre-merge evidence" do
      result = described_class.compare_with_main(manifest: manifest, selections: selections, main_sha: "m" * 40)
      expect(result["status"]).to eq("matched")
      expect(result["attributed"].first).to include("target_label" => "//:grade/rspec", "pre_merge_outcome" => "passed")
    end

    it "reports a changed target graph as an explicit delta" do
      selections << { "name" => "new", "target_label" => "//:grade/new", "affected" => true, "target_fingerprints" => {} }
      result = described_class.compare_with_main(manifest: manifest, selections: selections, main_sha: "m")
      expect(result["status"]).to eq("delta")
      expect(result["deltas"]).to eq([ { "target_label" => "//:grade/new", "name" => "new", "reason" => "not_selected_pre_merge" } ])
    end

    it "does not weaken environment parity (cached prepare layers must keep the fingerprint)" do
      selections.first["target_fingerprints"]["environment_fingerprint"] = "e-different"
      result = described_class.compare_with_main(manifest: manifest, selections: selections, main_sha: "m")
      expect(result["deltas"].first["reason"]).to eq("environment_fingerprint_changed")
    end

    it "treats a changed command as a delta" do
      selections.first["target_fingerprints"]["command_fingerprint"] = "c-other"
      expect(described_class.compare_with_main(manifest: manifest, selections: selections, main_sha: "m")["deltas"].first["reason"]).to eq("command_fingerprint_changed")
    end

    it "cannot prove parity from a missing fingerprint" do
      selections.first["target_fingerprints"] = {}
      expect(described_class.compare_with_main(manifest: manifest, selections: selections, main_sha: "m")["status"]).to eq("delta")
    end

    it "makes every selected target a delta when there is no pre-merge manifest" do
      result = described_class.compare_with_main(manifest: nil, selections: selections, main_sha: "m")
      expect(result).to include("status" => "no_manifest")
      expect(result["deltas"].first["reason"]).to eq("no_pre_merge_evidence")
    end

    it "ignores targets main did not select" do
      selections.first["affected"] = false
      expect(described_class.compare_with_main(manifest: manifest, selections: selections, main_sha: "m")["status"]).to eq("matched")
    end

    it "flags a target whose pre-merge result was not green" do
      m = manifest(targets: [ target("rspec", outcome: "inconclusive") ])
      expect(described_class.compare_with_main(manifest: m, selections: selections, main_sha: "m")["deltas"].first["reason"]).to eq("pre_merge_inconclusive")
    end
  end

  describe ".manifest_for_landed_sha / .diagnostics" do
    it "finds the manifest through the Job's landed SHA and exposes diagnostics" do
      workflow = store(manifest)
      job.update_column(:landed_sha, "m" * 40)
      expect(described_class.manifest_for_landed_sha(repository: repository, sha: "m" * 40)).to include("head_sha" => sha)
      diagnostics = described_class.diagnostics(workflow)
      expect(diagnostics["manifest"]["targets"].first).to include("name" => "rspec", "outcome" => "passed")
    end

    it "returns nil diagnostics when nothing was recorded" do
      expect(described_class.diagnostics(Workflow.create!(job: job, trigger_kind: "initial"))).to be_nil
    end
  end

  describe ".build" do
    it "types outcomes from grader steps and reuses carried-forward evidence" do
      workflow = Workflow.create!(job: job, trigger_kind: "auto_merge")
      step = instance_double(Step, details: { "name" => "rspec", "required" => true, "target_label" => "//:grade/rspec", "target_fingerprints" => { "command_fingerprint" => "c", "environment_fingerprint" => "e" }, "source_snapshot" => { "source_sha" => sha } }, state: "succeeded")
      allow(GraderOutcome).to receive(:for_step).with(step).and_return(GraderOutcome::Result.new("passed", "grader_passed", {}))
      built = described_class.build(
        workflow: workflow, head_sha: sha, tree_sha: "t", base_sha: "b", base_ref: "main", grader_steps: [ step ],
        carried_forward: [ { "name" => "lint", "required" => true, "target_fingerprints" => { "command_fingerprint" => "c2", "environment_fingerprint" => "e2" } } ]
      )
      expect(built["targets"].map { |t| [ t["name"], t["outcome"], t["source"], t["has_evidence"] ] }).to eq(
        [ [ "rspec", "passed", "ran", true ], [ "lint", "passed", "carried_forward", true ] ]
      )
      expect(built["source_snapshot"]).to eq("source_sha" => sha)
    end
  end
end
