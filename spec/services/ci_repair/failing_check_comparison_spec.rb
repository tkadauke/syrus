require "rails_helper"

RSpec.describe CiRepair::FailingCheckComparison do
  let(:repository) { Factories.repository }
  let(:job) do
    Factories.job_record(
      repository: repository,
      pr_checks_failing_names: [ "rspec", { "name" => "frontend" } ]
    )
  end

  def record_health!(sha:, ci_failed_checks: nil, grader_failed_names: nil)
    MainBranchHealthCheck.create!(
      repository: repository,
      sha: sha,
      checked_at: Time.current,
      source: "ci_poll",
      ci_failed_checks: ci_failed_checks,
      grader_failed_names: grader_failed_names
    )
  end

  it "returns only failures introduced relative to every record for the requested base" do
    record_health!(sha: "base", ci_failed_checks: [ { "name" => " rspec " } ])
    record_health!(sha: "base", grader_failed_names: [ { name: "lint" }, "rspec", nil ])

    job.update!(pr_checks_failing_names: [ "rspec", { "name" => "frontend" }, "", "frontend" ])

    expect(described_class.call(job: job, base_sha: "base")).to eq([ "frontend" ])
  end

  it "returns nil when the pull request has no named failures" do
    job.update!(pr_checks_failing_names: [ "", { "name" => nil } ])

    expect(described_class.call(job: job, base_sha: "base")).to be_nil
  end

  it "returns nil when no base health evidence exists" do
    expect(described_class.call(job: job, base_sha: "missing")).to be_nil
  end

  it "falls back to the newest repository health record when the requested SHA is unknown" do
    record_health!(sha: "older", ci_failed_checks: [ "rspec" ])
    record_health!(sha: "newer", ci_failed_checks: [ "rspec", "frontend" ])

    expect(described_class.call(job: job, base_sha: "missing")).to be_nil
  end

  it "prefers a stacked parent's failures over repository health when requested" do
    parent = Factories.job_record(
      repository: repository,
      issue_number: 41,
      pr_checks_failing_names: [ { "name" => "rspec" } ]
    )
    job.update!(parent_job: parent)
    record_health!(sha: "main", ci_failed_checks: [ "frontend" ])

    expect(
      described_class.call(job: job, base_sha: "parent-head", stacked_parent_fallback: true)
    ).to eq([ "frontend" ])
  end

  it "does not use the stacked parent unless its fallback is requested" do
    parent = Factories.job_record(
      repository: repository,
      issue_number: 41,
      pr_checks_failing_names: [ "rspec" ]
    )
    job.update!(parent_job: parent)
    record_health!(sha: "main", ci_failed_checks: [ "frontend" ])

    expect(described_class.call(job: job, base_sha: "parent-head")).to eq([ "rspec" ])
  end
end
