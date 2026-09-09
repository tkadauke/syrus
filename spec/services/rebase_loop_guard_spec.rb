require "rails_helper"
require "ostruct"

RSpec.describe RebaseLoopGuard do
  let(:job) { Factories.job(pr_mergeable: false) }

  def pr(head_sha: "head", base_sha: nil, base_ref: "main")
    OpenStruct.new(
      head: OpenStruct.new(sha: head_sha),
      base: OpenStruct.new(sha: base_sha, ref: base_ref)
    )
  end

  def client(base_sha)
    instance_double(GithubClient, branch_head_sha: base_sha)
  end

  def no_op_rebase(post_sha: "head", base_sha: "base")
    Workflows::Rebase.instantiate(job: job).update!(
      state: "succeeded",
      artifacts: {
        "auto_rebase_result" => {
          "reason" => "rebased",
          "changed" => false,
          "post_sha" => post_sha,
          "base_sha" => base_sha
        }
      }
    )
  end

  def already_landed_rebase(pre_sha: "head", post_sha: "base", base_sha: "base")
    Workflows::StackRebase.instantiate(job: job).update!(
      state: "succeeded",
      artifacts: {
        StackRebasePlan::RESULTS_ARTIFACT => [
          {
            "job_id" => job.id,
            "result" => {
              "reason" => AutoRebase::ALREADY_LANDED_REASON,
              "changed" => false,
              "pre_sha" => pre_sha,
              "post_sha" => post_sha,
              "base_sha" => base_sha
            }
          }
        ]
      }
    )
  end

  it "matches a no-op rebase when the PR head is unchanged and GitHub omits the base sha" do
    no_op_rebase

    expect(described_class.noop_rebase_for?(job: job, pr: pr(base_sha: nil))).to be true
  end

  it "does not match when the PR head advanced after the no-op rebase" do
    no_op_rebase(post_sha: "old-head")

    expect(described_class.noop_rebase_for?(job: job, pr: pr(head_sha: "new-head"))).to be false
  end

  it "does not match when GitHub provides a different base sha" do
    no_op_rebase(base_sha: "old-base")

    expect(described_class.noop_rebase_for?(job: job, pr: pr(base_sha: "new-base"))).to be false
  end

  it "does not match when the live base branch advanced beyond GitHub's PR payload" do
    no_op_rebase(base_sha: "old-base")

    expect(
      described_class.noop_rebase_for?(
        job: job,
        pr: pr(base_sha: "old-base", base_ref: "main"),
        client: client("new-live-base")
      )
    ).to be false
  end

  it "fetches the live base branch named by the PR" do
    no_op_rebase(base_sha: "base")
    github = client("base")

    expect(described_class.noop_rebase_for?(job: job, pr: pr(base_ref: "syrus/parent"), client: github)).to be true
    expect(github).to have_received(:branch_head_sha).with(job.repository.slug, "syrus/parent")
  end

  it "matches an already-landed stack rebase against the unchanged PR head" do
    already_landed_rebase(pre_sha: "head", post_sha: "base", base_sha: "base")

    expect(described_class.noop_rebase_for?(job: job, pr: pr(head_sha: "head"), client: client("base"))).to be true
  end

  it "does not match an already-landed stack rebase after the PR head changes" do
    already_landed_rebase(pre_sha: "old-head", post_sha: "base", base_sha: "base")

    expect(described_class.noop_rebase_for?(job: job, pr: pr(head_sha: "new-head"), client: client("base"))).to be false
  end

  it "keeps matching an already-landed stack rebase after the base branch advances" do
    already_landed_rebase(pre_sha: "head", post_sha: "old-base", base_sha: "old-base")

    expect(described_class.noop_rebase_for?(job: job, pr: pr(head_sha: "head"), client: client("new-base"))).to be true
  end
end
