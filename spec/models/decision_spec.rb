require "rails_helper"

RSpec.describe Decision do
  let(:repo) { Factories.repository }

  def decision(**overrides)
    described_class.new({
      problem_code: "grader_failure", signature: "grader_failure:abc",
      title: "rspec failed on JOB-1", repository: repo
    }.merge(overrides))
  end

  it "requires a code the shared vocabulary knows" do
    expect(decision).to be_valid
    expect(decision(problem_code: "not_a_problem")).not_to be_valid
  end

  # A decision offering an action nobody can execute reads as answerable and
  # is not.
  it "requires its actions to name real pending actions" do
    expect(decision(actions: [ { "action_key" => "force_rebase" } ])).to be_valid

    invalid = decision(actions: [ { "action_key" => "make_it_work" } ])
    expect(invalid).not_to be_valid
    expect(invalid.errors.full_messages.join).to match(/unknown pending action/)
  end

  it "exposes its problem in the shared vocabulary" do
    record = decision(evidence: { "grader_name" => "rspec" })

    expect(record.problem.code).to eq("grader_failure")
    expect(record.problem.evidence).to eq(grader_name: "rspec")
  end

  it "records who decided and how" do
    record = decision
    record.save!

    record.decide!(resolution: "dismissed", user: repo.user, reason: "known upstream issue")

    expect(record.reload).to be_decided
    expect(record.resolution).to eq("dismissed")
    expect(record.decided_by_user).to eq(repo.user)
    expect(record.decided_at).to be_present
  end

  it "refuses a resolution outside the three" do
    record = decision
    record.save!

    expect { record.decide!(resolution: "ignored") }.to raise_error(ArgumentError, /unknown resolution/)
  end

  it "knows when it has expired" do
    expect(decision(expires_at: 1.hour.ago)).to be_expired
    expect(decision(expires_at: 1.hour.from_now)).not_to be_expired
    expect(decision).not_to be_expired
  end
end
