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
      { "auto_rebase_result" => { "succeeded" => true, "reason" => "rebased", "pre_sha" => "a" * 40 } }
    end

    it "passes when the recorded patch id is still on the branch" do
      expect { verify!(fake_git(branch_patch_ids: [ "recorded-patch-id" ])) }.not_to raise_error

      expect(workflow.reload.artifact(described_class::PUBLICATION_PROVENANCE_ARTIFACT))
        .to include("verified" => true)
    end

    # The conservative half: a clean rebase has no reason to rewrite the fix, so
    # a missing patch id there really does mean the branch dropped it.
    it "still refuses when the fix is simply absent" do
      expect { verify!(fake_git(branch_patch_ids: [ "some-other-patch" ])) }
        .to raise_error(described_class::MissingLatestFix, /Run #198842/)
    end
  end

  # Patch-id identity is required even when the rebase conflicted, and that is
  # deliberate. A conflict resolution does change content, so a legitimately
  # rewritten fix cannot match -- but neither can a resolution that dropped the
  # latest fix and resurrected an older one, and from patch ids alone those two
  # are indistinguishable. `Steps::ForcePush` has a spec for the second case
  # (refuses when a rebase resurrects a visual-review-rejected fix), so relaxing
  # this for the first would publish the second.
  #
  # The cost is real: a branch whose conflicting rebase rewrites its tip fix can
  # never satisfy this guard, and one such pull request filed 64 failed rebase
  # workflows. That is a throughput bug and it is the lesser one -- publishing a
  # branch that silently lost its latest fix is a correctness bug. Fixing the
  # loop has to come from bounding the retries or from operator action, not from
  # weakening this check.
  context "when the rebase conflicted and the agent resolved it" do
    let(:artifacts) do
      { "auto_rebase_result" => { "succeeded" => false, "reason" => "conflict", "pre_sha" => "a" * 40 } }
    end

    it "still refuses a fix whose patch id is absent, however the branch got that way" do
      expect { verify!(fake_git(branch_patch_ids: [ "rewritten-patch-id" ])) }
        .to raise_error(described_class::MissingLatestFix, /Run #198842/)
    end

    it "accepts the fix when its patch id did survive the resolution" do
      expect { verify!(fake_git(branch_patch_ids: [ "recorded-patch-id" ])) }.not_to raise_error

      expect(workflow.reload.artifact(described_class::PUBLICATION_PROVENANCE_ARTIFACT))
        .to include("verified" => true)
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
