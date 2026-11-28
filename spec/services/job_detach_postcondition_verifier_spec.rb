require "rails_helper"

RSpec.describe JobDetachPostconditionVerifier do
  let(:owner) { Factories.user }
  let(:repository) { Factories.repository(user: owner, default_branch: "main") }
  let(:parent) { Factories.job_record(user: owner, repository: repository, branch_name: "syrus/parent") }
  let(:job) do
    Factories.job_record(
      user: owner, repository: repository, branch_name: "syrus/child", pr_number: 42, parent_job: parent
    )
  end
  let(:head) { "a" * 40 }
  let(:live_head) { head }
  let(:live_base) { "main" }
  let(:client) { instance_double(GithubClient, branch_head_sha: head) }
  let(:head_ref) { double("head", sha: live_head) }
  let(:base_ref) { double("base", ref: live_base) }
  let(:pr) { double("pull request", head: head_ref, base: base_ref) }

  before do
    allow(client).to receive(:pull_request).and_return(pr)
  end

  def verify!
    described_class.verify!(
      job: job, destination_base: "main", expected_head: head, former_parent_id: parent.id, client: client
    )
  end

  it "reports a stale pull-request head" do
    job.update!(parent_job: nil)
    allow(head_ref).to receive(:sha).and_return("b" * 40)

    expect { verify! }.to raise_error(described_class::Mismatch, /PR head/)
  end

  it "reports a stale pull-request base" do
    job.update!(parent_job: nil)
    allow(base_ref).to receive(:ref).and_return("syrus/parent")

    expect { verify! }.to raise_error(described_class::Mismatch, /PR base/)
  end

  it "reports a residual derived stack parent" do
    expect { verify! }.to raise_error(described_class::Mismatch, /stack parent/)
  end

  it "reports a residual explicit dependency" do
    job.update!(parent_job: nil)
    JobDependency.create!(job: job, depends_on_job: parent, source: "manual", satisfaction_mode: "success")

    expect { verify! }.to raise_error(described_class::Mismatch, /explicit dependency/)
  end
end
