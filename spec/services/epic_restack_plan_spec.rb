require "rails_helper"

RSpec.describe EpicRestackPlan do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:epic) { Factories.epic(user: user, repository: repository) }

  def child(issue_number:, state: "approved", branch: "syrus/issue-#{issue_number}", pr: issue_number, **attrs)
    Factories.job_record(**{
      user: user,
      repository: repository,
      epic: epic,
      issue_number: issue_number,
      state: state,
      branch_name: branch,
      pr_number: pr
    }.merge(attrs))
  end

  it "orders open child branches topologically and reports target bases" do
    root = child(issue_number: 11)
    middle = child(issue_number: 12)
    leaf = child(issue_number: 13, commits_behind_base: 2)
    JobDependency.create!(job: middle, depends_on_job: root, source: "manual")
    JobDependency.create!(job: leaf, depends_on_job: middle, source: "manual")

    plan = described_class.for(epic)
    order = plan.fetch("branch_order")

    expect(order.map { |entry| entry.fetch("job_id") }).to eq([ root.id, middle.id, leaf.id ])
    expect(order.map { |entry| entry.fetch("target_base") }).to eq([
      repository.default_branch,
      root.branch_name,
      middle.branch_name
    ])
    expect(order.last).to include("commits_behind" => 2, "pr_number" => 13)
    expect(plan.fetch("skipped_nodes")).to be_empty
  end

  it "skips blocked, merged, missing-PR, fan-in, and blocked descendant nodes conservatively" do
    root = child(issue_number: 21)
    merged = child(issue_number: 22, state: "closed", closure_reason: "pr_merged")
    missing_pr = child(issue_number: 23, pr: nil)
    fan_in = child(issue_number: 24)
    descendant = child(issue_number: 25)
    blocked = child(issue_number: 26, state: "blocked_by_epic")
    Factories.legacy_job_dependency(job: fan_in, depends_on_job: root)
    Factories.legacy_job_dependency(job: fan_in, depends_on_job: missing_pr)
    JobDependency.create!(job: descendant, depends_on_job: fan_in, source: "manual")

    plan = described_class.for(epic)

    expect(plan.fetch("branch_order").map { |entry| entry.fetch("job_id") }).to eq([ root.id ])
    expect(plan.fetch("skipped_nodes").map { |entry| [ entry.fetch("job_id"), entry.fetch("reason") ] }).to include(
      [ merged.id, "merged" ],
      [ missing_pr.id, "missing_pr" ],
      [ fan_in.id, "fan_in_dependency" ],
      [ descendant.id, "dependency_not_restacked" ],
      [ blocked.id, "blocked" ]
    )
  end
end
