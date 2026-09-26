require "rails_helper"
require "open3"

RSpec.describe Steps::ForcePush do
  let(:job) { Factories.job }
  let(:workflow) { Workflows::Rebase.instantiate(job: job) }
  let(:step) { workflow.steps.find_by!(kind: "force_push") }
  let(:run) { Run.create!(job: job, step: step, trigger_kind: "rebase") }

  def patch_id_for(diff)
    output, status = Open3.capture2e("git", "patch-id", "--stable", stdin_data: diff)
    raise output unless status.success?

    output.split(/\s+/).first
  end

  def patch_diff(line)
    <<~DIFF
      diff --git a/app/frontend/SplitDiff.tsx b/app/frontend/SplitDiff.tsx
      index e69de29..7898192 100644
      --- a/app/frontend/SplitDiff.tsx
      +++ b/app/frontend/SplitDiff.tsx
      @@ -0,0 +1 @@
      +#{line}
    DIFF
  end

  def record_latest_coding_handoff_fix!(patch_id:, run_id: 200, head_sha: "latest-fix")
    Workflow.create!(
      job: job,
      trigger_kind: "coding_handoff",
      artifacts: {
        "latest_coding_handoff_fix" => {
          "workflow_id" => 123,
          "step_id" => 456,
          "run_id" => run_id,
          "head_sha" => head_sha,
          "patch_id" => patch_id,
          "recorded_at" => Time.current.iso8601,
          "visual_review" => {
            "status" => "not_reviewed_after_latest_fix",
            "checked_after_fix" => false
          }
        }
      }
    )
  end

  it "skips pushing when deterministic auto-rebase already proved the branch was unchanged" do
    workflow.set_artifact!("auto_rebase_result", {
      "reason" => "rebased",
      "changed" => false,
      "post_sha" => "abc",
      "base_sha" => "base"
    })
    handler = described_class.new(run)

    expect(handler).not_to receive(:workspace)

    handler.call

    expect(run.job_logs.pluck(:chunk).join("\n")).to include("force_push: skipped")
  end

  # A Run resumed from a failed step reaches this handler directly, without
  # Steps::AutoRebase having just run, so the refusal has to live here too.
  # Pushing a branch the rebase emptied is what wiped the already-landed closed-PR regression's PR to zero
  # commits after its work had already landed.
  it "refuses to push a branch whose work is already on the base" do
    workflow.set_artifact!("auto_rebase_result", {
      "reason" => ::AutoRebase::ALREADY_LANDED_REASON,
      "changed" => false,
      "succeeded" => true,
      "post_sha" => "base",
      "base_sha" => "base"
    })
    handler = described_class.new(run)

    expect(handler).not_to receive(:workspace)

    handler.call

    expect(run.job_logs.pluck(:chunk).join("\n")).to include("already on the base")
  end

  it "pushes with an explicit lease from the auto_rebase remote SHA" do
    workflow.set_artifact!("auto_rebase_result", {
      "reason" => "conflict",
      "pre_sha" => "abc123",
      "base_sha" => "base123"
    })
    handler = described_class.new(run)
    workspace = instance_double(WorkflowWorkspace,
                                setup: nil,
                                branch_name: "syrus/issue-42",
                                path: Pathname.new("/tmp/workspace"))
    git = instance_double(GitRunner)

    allow(handler).to receive(:workspace).and_return(workspace)
    allow(handler).to receive(:streaming_git).and_return(git)
    allow(GithubClient).to receive(:for).and_return(instance_double(GithubClient, access_token: "token"))
    allow(job.repository).to receive(:authenticated_push_url).with("token").and_return("https://push.example/repo.git")
    allow(git).to receive(:run)
    allow(git).to receive(:run).with("rev-parse", "HEAD", chdir: "/tmp/workspace").and_return("head456\n")
    allow(handler).to receive(:diff_against_sha).with("base123").and_return(<<~DIFF)
      diff --git a/foo.rb b/foo.rb
      index 1111111..2222222 100644
      --- a/foo.rb
      +++ b/foo.rb
      @@ -1 +1,2 @@
       old
      +bar
    DIFF

    handler.call

    expect(git).to have_received(:run).with(
      "push",
      "--force-with-lease=refs/heads/syrus/issue-42:abc123",
      "https://push.example/repo.git",
      "HEAD:refs/heads/syrus/issue-42",
      chdir: "/tmp/workspace"
    )
    version = job.diff_review_versions.sole
    expect(version).to have_attributes(
      base_sha: "base123",
      head_sha: "head456",
      trigger_kind: "rebase",
      label: "Rebase",
      reason: "rebase"
    )
  end

  it "records provenance and force-pushes when the latest coding handoff fix patch survived rebase" do
    latest_patch = patch_diff("fixed table rows")
    record_latest_coding_handoff_fix!(patch_id: patch_id_for(latest_patch), run_id: 347, head_sha: "fix347")
    workflow.set_artifact!("auto_rebase_result", {
      "reason" => "conflict",
      "pre_sha" => "abc123",
      "base_sha" => "base123"
    })
    handler = described_class.new(run)
    workspace = instance_double(WorkflowWorkspace,
                                setup: nil,
                                branch_name: "syrus/issue-42",
                                path: Pathname.new("/tmp/workspace"))
    git = instance_double(GitRunner)

    allow(handler).to receive(:workspace).and_return(workspace)
    allow(handler).to receive(:streaming_git).and_return(git)
    allow(GithubClient).to receive(:for).and_return(instance_double(GithubClient, access_token: "token"))
    allow(job.repository).to receive(:authenticated_push_url).with("token").and_return("https://push.example/repo.git")
    allow(git).to receive(:run)
    allow(git).to receive(:run).with("rev-parse", "HEAD", chdir: "/tmp/workspace").and_return("rebased-head\n")
    allow(git).to receive(:run).with("log", "--format=email", "--patch", "base123..HEAD", chdir: "/tmp/workspace").and_return(latest_patch)
    allow(handler).to receive(:diff_against_sha).with("base123").and_return(latest_patch)

    handler.call

    expect(git).to have_received(:run).with(
      "push",
      "--force-with-lease=refs/heads/syrus/issue-42:abc123",
      "https://push.example/repo.git",
      "HEAD:refs/heads/syrus/issue-42",
      chdir: "/tmp/workspace"
    )
    expect(workflow.reload.artifact("coding_handoff_publication_provenance")).to include(
      "branch_head_sha" => "rebased-head",
      "verified" => true,
      "visual_review" => include("status" => "not_reviewed_after_latest_fix")
    )
  end

  it "refuses to force-push when rebase resurrected an older visual-review-failed handoff fix instead of the latest fix" do
    rejected_patch = patch_diff("display grid rows")
    latest_patch = patch_diff("fixed table rows")
    record_latest_coding_handoff_fix!(patch_id: patch_id_for(latest_patch), run_id: 347, head_sha: "fix347")
    workflow.set_artifact!("auto_rebase_result", {
      "reason" => "conflict",
      "pre_sha" => "abc123",
      "base_sha" => "base123"
    })
    handler = described_class.new(run)
    workspace = instance_double(WorkflowWorkspace,
                                setup: nil,
                                branch_name: "syrus/issue-42",
                                path: Pathname.new("/tmp/workspace"))
    git = instance_double(GitRunner)

    allow(handler).to receive(:workspace).and_return(workspace)
    allow(handler).to receive(:streaming_git).and_return(git)
    allow(GithubClient).to receive(:for).and_return(instance_double(GithubClient, access_token: "token"))
    allow(job.repository).to receive(:authenticated_push_url).with("token").and_return("https://push.example/repo.git")
    allow(git).to receive(:run)
    allow(git).to receive(:run).with("rev-parse", "HEAD", chdir: "/tmp/workspace").and_return("rebased-head\n")
    allow(git).to receive(:run).with("log", "--format=email", "--patch", "base123..HEAD", chdir: "/tmp/workspace").and_return(rejected_patch)

    expect { handler.call }.to raise_error(Steps::Base::StepFailed, /missing the latest coding_handoff_fix/)
    expect(git).not_to have_received(:run).with(
      "push",
      anything,
      "https://push.example/repo.git",
      "HEAD:refs/heads/syrus/issue-42",
      chdir: "/tmp/workspace"
    )
    expect(workflow.reload.artifact("coding_handoff_publication_provenance")).to include(
      "branch_head_sha" => "rebased-head",
      "verified" => false
    )
  end

  it "does not create a rebase diff version when the visible diff is empty" do
    workflow.set_artifact!("auto_rebase_result", {
      "reason" => "conflict",
      "pre_sha" => "abc123",
      "base_sha" => "base123"
    })
    handler = described_class.new(run)
    workspace = instance_double(WorkflowWorkspace,
                                setup: nil,
                                branch_name: "syrus/issue-42",
                                path: Pathname.new("/tmp/workspace"))
    git = instance_double(GitRunner)

    allow(handler).to receive(:workspace).and_return(workspace)
    allow(handler).to receive(:streaming_git).and_return(git)
    allow(GithubClient).to receive(:for).and_return(instance_double(GithubClient, access_token: "token"))
    allow(job.repository).to receive(:authenticated_push_url).with("token").and_return("https://push.example/repo.git")
    allow(git).to receive(:run)
    allow(git).to receive(:run).with("rev-parse", "HEAD", chdir: "/tmp/workspace").and_return("head456\n")
    allow(handler).to receive(:diff_against_sha).with("base123").and_return("")

    handler.call

    expect(job.diff_review_versions).to be_empty
  end

  it "leases against the post-rebase SHA after a clean deterministic auto-rebase already pushed" do
    workflow.set_artifact!("auto_rebase_result", {
      "reason" => "rebased",
      "changed" => true,
      "pre_sha" => "before123",
      "post_sha" => "after456"
    })
    handler = described_class.new(run)
    workspace = instance_double(WorkflowWorkspace,
                                setup: nil,
                                branch_name: "syrus/issue-42",
                                path: Pathname.new("/tmp/workspace"))
    git = instance_double(GitRunner)

    allow(handler).to receive(:workspace).and_return(workspace)
    allow(handler).to receive(:streaming_git).and_return(git)
    allow(GithubClient).to receive(:for).and_return(instance_double(GithubClient, access_token: "token"))
    allow(job.repository).to receive(:authenticated_push_url).with("token").and_return("https://push.example/repo.git")
    allow(git).to receive(:run)

    handler.call

    expect(git).to have_received(:run).with(
      "push",
      "--force-with-lease=refs/heads/syrus/issue-42:after456",
      "https://push.example/repo.git",
      "HEAD:refs/heads/syrus/issue-42",
      chdir: "/tmp/workspace"
    )
  end

  it "fails visibly when the lease-protected push is rejected" do
    workflow.set_artifact!("auto_rebase_result", {
      "reason" => "conflict",
      "pre_sha" => "abc123"
    })
    handler = described_class.new(run)
    workspace = instance_double(WorkflowWorkspace,
                                setup: nil,
                                branch_name: "syrus/issue-42",
                                path: Pathname.new("/tmp/workspace"))
    git = instance_double(GitRunner)

    allow(handler).to receive(:workspace).and_return(workspace)
    allow(handler).to receive(:streaming_git).and_return(git)
    allow(GithubClient).to receive(:for).and_return(instance_double(GithubClient, access_token: "token"))
    allow(job.repository).to receive(:authenticated_push_url).with("token").and_return("https://push.example/repo.git")
    allow(git).to receive(:run).and_raise(
      GitRunner::GitError.new(
        [ "push", "--force-with-lease=refs/heads/syrus/issue-42:abc123" ],
        1,
        "! [rejected] HEAD -> syrus/issue-42 (stale info)"
      )
    )

    expect { handler.call }.to raise_error(Steps::Base::StepFailed, /lease rejected/)
    expect(run.job_logs.pluck(:chunk).join("\n")).to include("remote branch moved")
  end

  describe "carry-forward of a green grade across a clean rebase (opt-in)" do
    def stub_git(handler, head: "newhead789")
      workspace = instance_double(WorkflowWorkspace, setup: nil, branch_name: "syrus/issue-42", path: Pathname.new("/tmp/workspace"))
      git = instance_double(GitRunner)
      allow(handler).to receive(:workspace).and_return(workspace)
      allow(handler).to receive(:streaming_git).and_return(git)
      allow(GithubClient).to receive(:for).and_return(instance_double(GithubClient, access_token: "token"))
      allow(job.repository).to receive(:authenticated_push_url).and_return("https://push.example/repo.git")
      allow(git).to receive(:run)
      allow(git).to receive(:run).with("rev-parse", "HEAD", chdir: "/tmp/workspace").and_return("#{head}\n")
      allow(git).to receive(:run).with("rev-parse", "HEAD^{tree}", chdir: "/tmp/workspace").and_return("newtree789\n")
      allow(git).to receive(:run).with("diff", "--name-only", "basesha...HEAD", chdir: "/tmp/workspace").and_return("app/models/job.rb\n")
      git
    end

    before do
      workflow.set_artifact!("auto_rebase_result", { "reason" => "rebased", "changed" => true, "succeeded" => true, "pre_sha" => "old", "post_sha" => "new" })
      job.update!(mergeability_base_sha: "basesha", mergeability_base_ref: "master")
      prior = Workflows::AutoMerge.instantiate(job: job)
      LandingValidationCache.record!(
        workflow: prior,
        head_sha: "oldhead",
        base_sha: "oldbase",
        base_ref: "master",
        grader_fingerprint: "fp",
        changed_files_fingerprint: LandingValidationCache.changed_files_fingerprint([ "app/models/job.rb" ])
      )
      allow(TargetGraph::Compiler).to receive(:compile).with(Pathname.new("/tmp/workspace")).and_return(TargetGraph.new)
      allow(GraderConclusionCache).to receive(:fingerprint_for_plan).and_return("fp")
    end

    it "re-stamps the landing validation for the new head/base when the repo trusts clean rebases" do
      job.repository.update!(trust_clean_rebase_grade: true)
      handler = described_class.new(run)
      target_graph = TargetGraph.new
      stub_git(handler)
      allow(TargetGraph::Compiler).to receive(:compile).with(Pathname.new("/tmp/workspace")).and_return(target_graph)
      expect(GraderConclusionCache).to receive(:fingerprint_for_plan).with(anything, target_graph: target_graph).and_return("fp")

      handler.call

      artifact = workflow.reload.artifact("landing_validation")
      expect(artifact).to be_present
      expect(artifact["head_sha"]).to eq("newhead789")
      expect(artifact["base_sha"]).to eq("basesha")
      expect(artifact["grader_fingerprint"]).to eq("fp")
      expect(artifact["changed_files_fingerprint"]).to eq(LandingValidationCache.changed_files_fingerprint([ "app/models/job.rb" ]))
      expect(artifact["required_graders_passed"]).to be(true)
    end

    it "does not re-stamp when the repository does not trust clean rebases" do
      job.repository.update!(trust_clean_rebase_grade: false)
      handler = described_class.new(run)
      stub_git(handler)

      handler.call

      expect(workflow.reload.artifact("landing_validation")).to be_nil
    end

    it "does not re-stamp when the rebase was not clean (agent resolved conflicts)" do
      job.repository.update!(trust_clean_rebase_grade: true)
      workflow.set_artifact!("auto_rebase_result", { "reason" => "conflict", "succeeded" => false })
      handler = described_class.new(run)
      stub_git(handler)

      handler.call

      expect(workflow.reload.artifact("landing_validation")).to be_nil
    end

    it "does not re-stamp when the current .syrus.yml changes the landing grader fingerprint" do
      job.repository.update!(trust_clean_rebase_grade: true)
      allow(GraderConclusionCache).to receive(:fingerprint_for_plan).and_return("new-fp")
      handler = described_class.new(run)
      stub_git(handler)

      handler.call

      expect(workflow.reload.artifact("landing_validation")).to be_nil
      expect(run.job_logs.pluck(:chunk).join("\n")).to include("required grader configuration changed")
    end

    it "re-stamps when the changed-file selection changes" do
      job.repository.update!(trust_clean_rebase_grade: true)
      handler = described_class.new(run)
      git = stub_git(handler)
      allow(git).to receive(:run).with("diff", "--name-only", "basesha...HEAD", chdir: "/tmp/workspace").and_return("app/services/new.rb\n")

      handler.call

      artifact = workflow.reload.artifact("landing_validation")
      expect(artifact).to be_present
      expect(artifact["head_sha"]).to eq("newhead789")
      expect(artifact["changed_files_fingerprint"]).to eq(LandingValidationCache.changed_files_fingerprint([ "app/services/new.rb" ]))
      expect(run.job_logs.pluck(:chunk).join("\n")).to include("force_push: carried green grade across clean rebase")
    end

    it "does not re-stamp when the PR has no prior green grade to carry forward" do
      job.repository.update!(trust_clean_rebase_grade: true)
      job.workflows.where(trigger_kind: "auto_merge").find_each { |wf| wf.update!(artifacts: {}) }
      handler = described_class.new(run)
      stub_git(handler)

      handler.call

      expect(workflow.reload.artifact("landing_validation")).to be_nil
    end
  end
end
