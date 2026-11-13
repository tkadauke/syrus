require "rails_helper"

# Grader output used to live in steps.details; with it externalized, building a
# Job detail payload must not select whole steps rows with an ORDER BY across a
# multi-id IN list.
RSpec.describe App::JobDetailPayload do
  include HeavySortStatements

  it "emits no heavy whole-row steps sort" do
    user = Factories.user
    job = Factories.job(user: user)
    job.workflows.first.steps.create!(
      kind: "grader", position: 80, state: "failed", finished_at: 1.minute.ago,
      details: { "name" => "rspec", "output" => "x" * 4_096 }
    )

    offenders = heavy_sort_statements do
      described_class.build(job: job, user: user)
      described_class.workflows(job: job, user: user)
    end

    # runs/workflows rows are covered by their own externalization work; this
    # spec pins the steps table.
    expect(offenders.grep(/steps[`"]?\.\*/i)).to be_empty
  end

  it "does not query step_detail_values once per step" do
    user = Factories.user
    job = Factories.job(user: user)
    workflow = job.workflows.first
    3.times do |n|
      workflow.steps.create!(kind: "grader", position: 70 + n, state: "failed", finished_at: 1.minute.ago,
                             details: { "name" => "g#{n}", "output" => "out #{n}" })
    end

    statements = []
    sub = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, p| statements << p[:sql] }
    begin
      described_class.workflows(job: job, user: user)
    ensure
      ActiveSupport::Notifications.unsubscribe(sub)
    end

    expect(statements.grep(/FROM "step_detail_values"/i).size).to be <= 1
  end
end
