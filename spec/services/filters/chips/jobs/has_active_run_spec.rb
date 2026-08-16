require "rails_helper"

RSpec.describe Filters::Chips::Jobs::HasActiveRun do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets") }

  def run_filter(op:)
    Filters::Compiler.call(
      Filters::Ast.parse("field" => "has_active_run", "op" => op),
      scope: Job.where(repository: repo),
      user: user,
      subject: :job
    )
  end

  let!(:with_active_run) do
    Factories.job(user: user, repository: repo).tap do |job|
      run = job.initial_run
      run.start!
      run.save!
    end
  end

  let!(:with_finished_run) do
    Factories.job(user: user, repository: repo).tap do |job|
      run = job.initial_run
      run.start!
      run.succeed!
      run.save!
    end
  end

  it "matches jobs with a queued or running Run" do
    expect(run_filter(op: "is_true")).to contain_exactly(with_active_run)
  end

  it "matches jobs without one" do
    expect(run_filter(op: "is_false")).to contain_exactly(with_finished_run)
  end

  context "when no Run is active" do
    before do
      Run.active.find_each do |run|
        run.cancel!
        run.save!
      end
    end

    it "matches nothing for is_true" do
      expect(run_filter(op: "is_true")).to be_empty
    end

    # NOT IN over an empty subquery is true for every row; the materialized
    # form has to agree, and `where.not(id: [])` compiles to 1=1.
    it "matches every job for is_false" do
      expect(run_filter(op: "is_false")).to contain_exactly(with_active_run, with_finished_run)
    end
  end

  # `Run.active.select(:job_id)` inlined as a subquery is a trap on MySQL:
  # `runs.state` is low-cardinality with no histogram, so the optimizer assumes
  # an even spread, estimates the subquery matches half the table, and
  # materializes it with a full scan of `runs` instead of using the covering
  # (state, job_id, updated_at) index. Production measured 4,660ms for the
  # subquery form against 1.26ms for a literal id list.
  it "does not embed a runs subquery in the generated SQL" do
    %w[is_true is_false].each do |op|
      sql = run_filter(op: op).to_sql

      expect(sql).not_to match(/SELECT\s+"?runs"?/i), "#{op} still inlines a runs subquery"
      expect(sql).not_to include("FROM \"runs\"")
    end
  end
end
