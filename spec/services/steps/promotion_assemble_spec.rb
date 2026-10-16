require "rails_helper"

RSpec.describe Steps::PromotionAssemble do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, default_branch: "main") }
  let(:job) do
    Job.create!(
      user: user,
      repository: repository,
      kind: "direct",
      issue_number: nil,
      issue_title: "Promote develop into main"
    )
  end
  let(:workflow) do
    Workflows::Promotion.instantiate(
      job: job,
      artifacts: { "promotion_source_branch" => "develop", "promotion_target_branch" => "main" }
    )
  end
  let(:step) { workflow.steps.find_by!(kind: "promotion_assemble") }
  let(:repair_step) { workflow.steps.where(kind: "promotion_repair", loop_id: nil).first! }
  let(:run) { Run.create!(job: job, step: step, trigger_kind: "promotion") }
  let(:handler) { described_class.new(run) }
  let(:branch_name) { "syrus/promote-develop-main-#{job.id}" }
  let(:workspace) do
    instance_double(WorkflowWorkspace, setup: nil, branch_name: branch_name, path: Pathname.new("/tmp/workspace"))
  end
  let(:git) { instance_double(GitRunner) }

  before do
    allow(handler).to receive(:workspace).and_return(workspace)
    allow(GitRunner).to receive(:new).and_return(git)
    allow(GithubClient).to receive(:for).and_return(instance_double(GithubClient, access_token: "token"))
    allow(repository).to receive(:authenticated_push_url).with("token").and_return("https://push.example/repo.git")
    allow(git).to receive(:run).with(
      "fetch", "https://push.example/repo.git",
      "+refs/heads/develop:refs/remotes/origin/develop",
      chdir: "/tmp/workspace"
    )
  end

  it "skips the top-level promotion_repair occurrence after a clean merge" do
    allow(git).to receive(:run).with(
      "merge", "--no-ff", "origin/develop", "-m", "Promote develop into main", chdir: "/tmp/workspace"
    )

    handler.call

    expect(repair_step.reload.state).to eq("skipped")
    expect(repair_step.details).to include(
      "skipped" => true,
      "skip_reason" => "promotion_assemble already succeeded; no conflict to resolve"
    )
    expect(workflow.reload.artifact("promotion_assemble_result")).to eq("succeeded" => true)
    expect(run.job_logs.pluck(:chunk).join("\n")).to include("clean merge")
  end

  it "aborts the merge and leaves promotion_repair queued on conflict" do
    allow(git).to receive(:run).with(
      "merge", "--no-ff", "origin/develop", "-m", "Promote develop into main", chdir: "/tmp/workspace"
    ).and_raise(GitRunner::GitError.new(%w[merge --no-ff origin/develop], 1, "CONFLICT (content): Merge conflict in app/models/job.rb"))
    allow(git).to receive(:run).with("merge", "--abort", chdir: "/tmp/workspace")

    handler.call

    expect(git).to have_received(:run).with("merge", "--abort", chdir: "/tmp/workspace")
    expect(repair_step.reload.state).to eq("queued")
    expect(workflow.reload.artifact("promotion_assemble_result")).to eq("succeeded" => false, "reason" => "conflict")
    expect(run.job_logs.pluck(:chunk).join("\n")).to include("falling through to promotion_repair")
  end

  it "fails with git output instead of reporting unrelated histories as a conflict" do
    allow(git).to receive(:run).with(
      "merge", "--no-ff", "origin/develop", "-m", "Promote develop into main", chdir: "/tmp/workspace"
    ).and_raise(GitRunner::GitError.new(
      %w[merge --no-ff origin/develop], 128, "fatal: refusing to merge unrelated histories"
    ))

    expect { handler.call }.to raise_error(
      Steps::Base::StepFailed, /fatal: refusing to merge unrelated histories/
    )
    expect(workflow.reload.artifact("promotion_assemble_result")).to be_nil
    expect(run.job_logs.pluck(:chunk).join("\n")).to include("fatal: refusing to merge unrelated histories")
  end

  it "fails with git output instead of reporting a merge hook failure as a conflict" do
    allow(git).to receive(:run).with(
      "merge", "--no-ff", "origin/develop", "-m", "Promote develop into main", chdir: "/tmp/workspace"
    ).and_raise(GitRunner::GitError.new(
      %w[merge --no-ff origin/develop], 1, "pre-merge-commit hook declined"
    ))

    expect { handler.call }.to raise_error(
      Steps::Base::StepFailed, /pre-merge-commit hook declined/
    )
    expect(workflow.reload.artifact("promotion_assemble_result")).to be_nil
  end

  it "fails with git output when a conflicted merge cannot be aborted" do
    allow(git).to receive(:run).with(
      "merge", "--no-ff", "origin/develop", "-m", "Promote develop into main", chdir: "/tmp/workspace"
    ).and_raise(GitRunner::GitError.new(
      %w[merge --no-ff origin/develop], 1, "CONFLICT (content): Merge conflict in app/models/job.rb"
    ))
    allow(git).to receive(:run).with("merge", "--abort", chdir: "/tmp/workspace").and_raise(
      GitRunner::GitError.new(%w[merge --abort], 128, "fatal: There is no merge to abort")
    )

    expect { handler.call }.to raise_error(
      Steps::Base::StepFailed, /fatal: There is no merge to abort/
    )
    expect(workflow.reload.artifact("promotion_assemble_result")).to be_nil
  end

  it "fails fast when no source branch artifact is present" do
    workflow.set_artifact!("promotion_source_branch", nil)

    expect { handler.call }.to raise_error(Steps::Base::StepFailed, /no source branch configured/)
  end

  it "does not skip a terminal promotion_repair step on a later clean result" do
    repair_step.start!
    repair_step.fail!
    repair_step.save!

    allow(git).to receive(:run).with(
      "merge", "--no-ff", "origin/develop", "-m", "Promote develop into main", chdir: "/tmp/workspace"
    )

    handler.call

    expect(repair_step.reload.state).to eq("failed")
  end
end
