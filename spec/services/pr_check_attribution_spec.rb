require "rails_helper"

RSpec.describe PrCheckAttribution do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:job) do
    Factories.job(repository: repository, issue_number: 42, pr_number: 7, state: "approved",
                  pr_checks_state: "failing", pr_checks_sha: "head-sha", mergeability_base_sha: "base-sha")
  end

  def record_base!(ci_health:, failed:, sha: "base-sha")
    MainBranchHealthCheck.create!(
      repository: repository, sha: sha, checked_at: Time.current, source: "ci_poll",
      ci_health: ci_health, ci_failed_checks: failed
    )
  end

  it "calls a failure inherited when every failing check is already red on the base" do
    job.update!(pr_checks_failing_names: [ "rspec", "react-tests" ])
    record_base!(ci_health: "broken", failed: [ { "name" => "react-tests" }, { "name" => "rspec" } ])

    result = described_class.for(job)

    expect(result).to be_inherited
    expect(result.own_names).to eq([])
    expect(result.base_sha).to eq("base-sha")
  end

  # The whole point of the distinction: one extra red check means this Job has
  # something of its own to answer for, even though the base is also broken.
  it "calls it the Job's own when any failing check is not red on the base" do
    job.update!(pr_checks_failing_names: [ "rspec", "my-new-check" ])
    record_base!(ci_health: "broken", failed: [ { "name" => "rspec" } ])

    result = described_class.for(job)

    expect(result).to be_own
    expect(result.own_names).to eq([ "my-new-check" ])
  end

  it "does not excuse a Job when the base is healthy" do
    job.update!(pr_checks_failing_names: [ "rspec" ])
    record_base!(ci_health: "healthy", failed: [])

    expect(described_class.for(job)).to be_own
  end

  it "reports unknown rather than guessing when no failing names were recorded" do
    job.update!(pr_checks_failing_names: nil)
    record_base!(ci_health: "broken", failed: [ { "name" => "rspec" } ])

    result = described_class.for(job)

    expect(result).to be_unknown
    expect(result.reason).to eq("no_failing_check_names_recorded")
  end

  it "reports unknown rather than guessing when the base has no health record" do
    job.update!(pr_checks_failing_names: [ "rspec" ])

    result = described_class.for(job)

    expect(result).to be_unknown
    expect(result.reason).to eq("no_base_health_record")
  end

  # Collectors write GitHub's richer check hashes; older rows may hold bare
  # strings. Both have to compare.
  it "compares hash-shaped and string-shaped check records alike" do
    job.update!(pr_checks_failing_names: [ "rspec" ])
    record_base!(ci_health: "broken", failed: [ "rspec" ])

    expect(described_class.for(job)).to be_inherited
  end

  it "falls back to the repository's latest settled poll when the exact base SHA is unknown" do
    job.update!(pr_checks_failing_names: [ "rspec" ], mergeability_base_sha: nil)
    record_base!(ci_health: "broken", failed: [ { "name" => "rspec" } ], sha: "some-other-main-sha")

    result = described_class.for(job)

    expect(result).to be_inherited
    expect(result.base_sha).to eq("some-other-main-sha")
  end

  it "prefers the base SHA captured with PR checks over stale mergeability state" do
    job.update!(
      pr_checks_failing_names: [ "rspec" ],
      pr_checks_base_sha: "current-base-sha",
      mergeability_base_sha: "stale-base-sha"
    )
    record_base!(ci_health: "broken", failed: [ { "name" => "rspec" } ], sha: "stale-base-sha")
    record_base!(ci_health: "healthy", failed: [], sha: "current-base-sha")

    result = described_class.for(job)

    expect(result).to be_own
    expect(result.base_sha).to eq("current-base-sha")
  end

  it "exposes the evidence both sides of the comparison rest on" do
    job.update!(pr_checks_failing_names: [ "rspec", "mine" ])
    record_base!(ci_health: "broken", failed: [ { "name" => "rspec" } ])

    expect(described_class.for(job).to_h).to include(
      "verdict" => "own",
      "failing_names" => [ "mine", "rspec" ],
      "base_failing_names" => [ "rspec" ],
      "own_names" => [ "mine" ],
      "base_sha" => "base-sha"
    )
  end
end
