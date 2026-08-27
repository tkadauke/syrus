require "rails_helper"

RSpec.describe Filters::Chips::Jobs::DeliveryStatus do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user) }

  def run_filter(op:, value:)
    Filters::Compiler.call(
      Filters::Ast.parse("field" => "delivery_status", "op" => op, "value" => value),
      scope: Job.where(repository: repo),
      user: user,
      subject: :job
    )
  end

  let!(:queued_job) { Factories.job_record(repository: repo, state: "queued") }
  let!(:approved_job) { Factories.job_record(repository: repo, state: "approved") }
  let!(:failed_job) { Factories.job_record(repository: repo, state: "failed") }

  it "matches jobs not yet approved for is waiting_for_local_approval" do
    expect(run_filter(op: "is", value: "waiting_for_local_approval")).to contain_exactly(queued_job)
  end

  it "matches approved/landing jobs for approved_for_local_landing" do
    expect(run_filter(op: "is", value: "approved_for_local_landing")).to contain_exactly(approved_job)
  end

  it "matches failed jobs for delivery_needs_attention" do
    expect(run_filter(op: "is", value: "delivery_needs_attention")).to contain_exactly(failed_job)
  end

  it "supports is_one_of across multiple statuses" do
    result = run_filter(op: "is_one_of", value: %w[waiting_for_local_approval delivery_needs_attention])
    expect(result).to contain_exactly(queued_job, failed_job)
  end

  it "returns none for an unrecognized status value" do
    expect(run_filter(op: "is", value: "not_a_real_status")).to be_empty
  end
end
