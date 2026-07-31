require "rails_helper"

RSpec.describe Steps::ForcePush do
  let(:job) { Factories.job }
  let(:workflow) { Workflows::Rebase.instantiate(job: job) }
  let(:step) { workflow.steps.find_by!(kind: "force_push") }
  let(:run) { Run.create!(job: job, step: step, trigger_kind: "rebase") }

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

  it "pushes with an explicit lease from the auto_rebase remote SHA" do
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
    allow(git).to receive(:run)

    handler.call

    expect(git).to have_received(:run).with(
      "push",
      "--force-with-lease=refs/heads/syrus/issue-42:abc123",
      "https://push.example/repo.git",
      "HEAD:refs/heads/syrus/issue-42",
      chdir: "/tmp/workspace"
    )
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
      allow(GraderConclusionCache).to receive(:fingerprint_for_plan).and_return("fp")
    end

    it "re-stamps the landing validation for the new head/base when the repo trusts clean rebases" do
      job.repository.update!(trust_clean_rebase_grade: true)
      handler = described_class.new(run)
      stub_git(handler)

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

    it "does not re-stamp when the changed-file selection changes" do
      job.repository.update!(trust_clean_rebase_grade: true)
      handler = described_class.new(run)
      git = stub_git(handler)
      allow(git).to receive(:run).with("diff", "--name-only", "basesha...HEAD", chdir: "/tmp/workspace").and_return("app/services/new.rb\n")

      handler.call

      expect(workflow.reload.artifact("landing_validation")).to be_nil
      expect(run.job_logs.pluck(:chunk).join("\n")).to include("changed-file selection changed")
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
