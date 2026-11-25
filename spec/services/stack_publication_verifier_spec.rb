require "rails_helper"

RSpec.describe StackPublicationVerifier do
  let(:job) do
    Factories.job_record(
      user: owner, repository: repository, issue_number: 91, pr_number: 91,
      branch_name: "syrus/child", state: "approved"
    )
  end
  let(:owner) { Factories.user }
  let(:repository) { Factories.repository(user: owner) }
  let(:workflow) { Workflows::StackRebase.instantiate(job: job) }
  let(:client) { instance_double(GithubClient) }
  let(:head_sha) { "c" * 40 }
  let(:base_sha) { "b" * 40 }
  let(:entry) do
    {
      "job_id" => job.id,
      "pr_number" => job.pr_number,
      "branch_name" => job.branch_name,
      "base_branch" => repository.default_branch,
      "parent_job_id" => nil
    }
  end
  let(:pr) do
    OpenStruct.new(
      head: OpenStruct.new(sha: head_sha),
      base: OpenStruct.new(ref: repository.default_branch, sha: base_sha),
      mergeable: true,
      mergeable_state: "clean"
    )
  end
  let(:verifier) do
    described_class.new(workflow: workflow, repository: repository, user: owner, client: client)
  end

  before do
    allow(LandingQueueProcessor).to receive(:refresh_snapshot!).and_return([])
  end

  it "rejects a publication plan without an intended head SHA before reading provider state" do
    expect {
      verifier.verify!(entries: [ entry ], expected_heads: {}, publication_mode: "already_correct")
    }.to raise_error(described_class::Mismatch, /did not include an intended head SHA/) { |error|
      expect(error.evidence).to include("job_id" => job.id, "pr_number" => job.pr_number)
    }
  end

  it "rejects a publication plan without a pull request number before reading provider state" do
    expect {
      verifier.verify!(entries: [ entry.merge("pr_number" => nil) ], expected_heads: { job.id => head_sha }, publication_mode: "already_correct")
    }.to raise_error(described_class::Mismatch, /did not include a pull request number/) { |error|
      expect(error.evidence).to include("job_id" => job.id, "expected_head_sha" => head_sha)
    }
  end

  it "reports all live branch, pull request, and topology postcondition mismatches" do
    parent = Factories.job_record(
      user: owner, repository: repository, issue_number: 92, pr_number: 92,
      branch_name: "syrus/parent", state: "approved"
    )
    job.update_columns(parent_job_id: parent.id)
    mismatched_pr = OpenStruct.new(
      head: OpenStruct.new(sha: "p" * 40),
      base: OpenStruct.new(ref: "wrong-base", sha: base_sha)
    )
    allow(client).to receive(:branch_head_sha).and_return("r" * 40)
    allow(client).to receive(:pull_request).and_return(mismatched_pr)

    expect {
      verifier.verify!(entries: [ entry ], expected_heads: { job.id => head_sha }, publication_mode: "rewritten")
    }.to raise_error(described_class::Mismatch) { |error|
      expect(error.evidence.fetch("mismatches")).to contain_exactly(
        "remote head is #{"r" * 40}, expected #{head_sha}",
        "PR head is #{"p" * 40}, expected #{head_sha}",
        "PR base is wrong-base, expected #{parent.branch_name}",
        "stack parent is #{parent.id}, expected none"
      )
    }
  end

  it "fails when live SHAs cannot support commits-behind recomputation" do
    pr_without_base_sha = OpenStruct.new(
      head: OpenStruct.new(sha: head_sha),
      base: OpenStruct.new(ref: repository.default_branch, sha: nil),
      mergeable: true,
      mergeable_state: "clean"
    )
    allow(client).to receive(:branch_head_sha).and_return(head_sha)
    allow(client).to receive(:pull_request).and_return(pr_without_base_sha)

    expect {
      verifier.verify!(entries: [ entry ], expected_heads: { job.id => head_sha }, publication_mode: "already_correct")
    }.to raise_error(described_class::Mismatch, /did not include head and base SHAs/)
  end

  it "fails when commits-behind cannot be derived from matching live state" do
    allow(client).to receive(:branch_head_sha).and_return(head_sha)
    allow(client).to receive(:pull_request).and_return(pr)
    allow(CommitsBehindCalculator).to receive(:call).and_return(nil)

    expect {
      verifier.verify!(entries: [ entry ], expected_heads: { job.id => head_sha }, publication_mode: "already_correct")
    }.to raise_error(described_class::Mismatch, /commits-behind could not be recomputed/)
  end
end
