require "rails_helper"

RSpec.describe CodingHandoffRevisionGuard do
  let(:job) { Factories.job_record(state: "implemented", pr_number: 4676, branch_name: "syrus/issue-1") }
  # The fix is recorded on the coding_handoff workflow that produced it; the
  # rebase workflow being verified carries only the rebase result. The guard
  # reaches across from one to the other, which is why both exist here.
  let!(:handoff_workflow) do
    Workflow.create!(
      job: job, trigger_kind: "coding_handoff", state: "succeeded",
      artifacts: fix_artifacts
    )
  end
  let(:workflow) do
    Workflow.create!(job: job, trigger_kind: "rebase", state: "running", artifacts: artifacts)
  end
  let(:fix) do
    {
      "workflow_id" => 1,
      "step_id" => 2,
      "run_id" => 198_842,
      "base_sha" => "b" * 40,
      "head_sha" => "a" * 40,
      "patch_id" => "recorded-patch-id",
      "recorded_at" => 2.weeks.ago.iso8601
    }
  end

  # The guard's only collaborator is git. Each spec declares what git answers
  # for the three questions the guard asks -- the branch head, the patch ids on
  # the branch, and whether the pre-rebase head contained the fix -- so a spec
  # reads as the git state it describes.
  def fake_git(branch_patch_ids:, contains: true)
    git = Object.new
    git.define_singleton_method(:run) do |*args, **_kwargs|
      case args.first
      when "rev-parse" then "c" * 40
      when "log" then branch_patch_ids.map { |id| "#{id} subject\n" }.join
      when "patch-id" then branch_patch_ids.map { |id| "#{id} #{id}\n" }.join
      when "merge-base"
        raise GitRunner::GitError.new([ "merge-base" ], 1, "not an ancestor") unless contains

        ""
      else ""
      end
    end
    git
  end

  def verify!(git)
    described_class.verify_latest_fix!(
      workflow: workflow,
      job: job,
      git: git,
      workspace_path: Pathname.new("/tmp/does-not-matter"),
      base_ref: "d" * 40,
      log: ->(_message, **) { }
    )
  end

  let(:fix_artifacts) { { described_class::LATEST_FIX_ARTIFACT => fix } }

  context "when the rebase applied cleanly" do
    let(:artifacts) do
      { described_class::REBASE_RESULT_ARTIFACT => { "succeeded" => true, "reason" => "rebased", "pre_sha" => "a" * 40 } }
    end

    it "passes when the recorded patch id is still on the branch" do
      expect { verify!(fake_git(branch_patch_ids: [ "recorded-patch-id" ])) }.not_to raise_error

      expect(workflow.reload.artifact(described_class::PUBLICATION_PROVENANCE_ARTIFACT))
        .to include("verified" => true, "verified_via" => "patch_id")
    end

    # The conservative half: a clean rebase has no reason to rewrite the fix, so
    # a missing patch id there really does mean the branch dropped it.
    it "still refuses when the fix is simply absent" do
      expect { verify!(fake_git(branch_patch_ids: [ "some-other-patch" ])) }
        .to raise_error(described_class::MissingLatestFix, /Run #198842/)
    end
  end

  # The regression. Resolving a conflict is what changes the content, so the
  # rebased commit cannot carry the patch id recorded before the rebase. While
  # the guard demanded identity it could never be satisfied for a branch whose
  # rebase conflicts -- and a branch far enough behind to need rebasing at all
  # is exactly the branch that conflicts.
  context "when the rebase conflicted and the agent resolved it" do
    let(:artifacts) do
      { described_class::REBASE_RESULT_ARTIFACT => { "succeeded" => false, "reason" => "conflict", "pre_sha" => "a" * 40 } }
    end

    it "accepts a rewritten fix the pre-rebase head contained" do
      expect { verify!(fake_git(branch_patch_ids: [ "rewritten-patch-id" ])) }.not_to raise_error

      expect(workflow.reload.artifact(described_class::PUBLICATION_PROVENANCE_ARTIFACT))
        .to include("verified" => true, "verified_via" => "conflict_resolution")
    end

    # Attribution has to stay honest in the other direction too: a conflict
    # does not excuse a fix that was never on the branch being rebased.
    it "refuses when the pre-rebase head did not contain the fix" do
      expect { verify!(fake_git(branch_patch_ids: [ "rewritten-patch-id" ], contains: false)) }
        .to raise_error(described_class::MissingLatestFix)
    end

    it "refuses when the rebase recorded no pre-rebase head to check against" do
      workflow.set_artifact!(described_class::REBASE_RESULT_ARTIFACT, { "succeeded" => false, "reason" => "conflict" })

      expect { verify!(fake_git(branch_patch_ids: [ "rewritten-patch-id" ])) }
        .to raise_error(described_class::MissingLatestFix)
    end
  end

  context "when no fix was ever recorded" do
    let(:artifacts) { {} }
    let(:fix_artifacts) { {} }

    it "has nothing to verify" do
      expect { verify!(fake_git(branch_patch_ids: [])) }.not_to raise_error
    end
  end
end
