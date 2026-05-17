require "rails_helper"

RSpec.describe Filters::Compiler do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets") }

  def compile(tree)
    # Scope to the test's own repo so leakage from prior specs in the
    # same suite (or before(:context) seeds) doesn't pollute results.
    described_class.call(Filters::Ast.parse(tree), scope: Job.where(repository: repo), user: user)
  end

  it "returns the base scope for an empty filter" do
    job = Factories.job(repository: repo, issue_number: 1)

    expect(compile({})).to include(job)
  end

  it "AND-composes two chips as conjunction" do
    other_repo = Factories.repository(user: user, owner: "acme", name: "api")
    match = Factories.job(repository: repo, issue_number: 1)
    Factories.job(repository: other_repo, issue_number: 2)

    result = compile("and" => [
      { "field" => "state", "op" => "is", "value" => match.state },
      { "field" => "repository_id", "op" => "is", "value" => repo.id }
    ])

    expect(result).to contain_exactly(match)
  end

  it "OR-group produces the union of branches" do
    queued_job = Factories.job(repository: repo, issue_number: 1)
    closed_job = Factories.job(repository: repo, issue_number: 2)
    closed_job.close!; closed_job.save!

    result = compile("and" => [
      { "or" => [
        { "field" => "state", "op" => "is", "value" => queued_job.state },
        { "field" => "state", "op" => "is", "value" => "closed" }
      ]}
    ])

    expect(result).to contain_exactly(queued_job, closed_job)
  end

  it "NOT chip excludes matched jobs" do
    open_job = Factories.job(repository: repo, issue_number: 1)
    closed_job = Factories.job(repository: repo, issue_number: 2)
    closed_job.close!; closed_job.save!

    result = compile("not" => { "field" => "state", "op" => "is", "value" => "closed" })

    expect(result).to contain_exactly(open_job)
  end

  it "NOT around an OR-group excludes the union (NAND)" do
    open_job = Factories.job(repository: repo, issue_number: 1)
    closed_job = Factories.job(repository: repo, issue_number: 2)
    closed_job.close!; closed_job.save!

    result = compile("not" => { "or" => [
      { "field" => "state", "op" => "is", "value" => "closed" }
    ]})

    expect(result).to contain_exactly(open_job)
  end

  it "raises UnknownFilterField for unregistered chip names" do
    expect {
      compile("field" => "made_up_filter", "op" => "is", "value" => "x")
    }.to raise_error(Filters::UnknownFilterField)
  end

  it "raises a clear error for unknown subjects" do
    expect {
      described_class.call(Filters::Ast.parse({}), scope: Job.all, subject: :made_up)
    }.to raise_error(ArgumentError, "unknown subject: made_up")
  end
end
