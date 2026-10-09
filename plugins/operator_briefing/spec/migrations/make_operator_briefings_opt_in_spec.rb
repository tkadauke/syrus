require "rails_helper"
require Rails.root.join("plugins/operator_briefing/db/migrate/20261009152613_make_operator_briefings_opt_in")

RSpec.describe MakeOperatorBriefingsOptIn do
  let(:migration) { described_class.new }
  let(:interested_user) { Factories.user }
  let(:uninterested_user) { Factories.user }
  let(:interested_repo) { Factories.repository(user: interested_user) }
  let(:uninterested_repo) { Factories.repository(user: uninterested_user) }

  before do
    PluginRecord.find_or_create_by!(name: "operator_briefing").update!(enabled: true, disableable: true)
  end

  it "grandfathers users with briefing interaction and disables users without it" do
    interested_job = Job.create!(user: interested_user, owner_user: interested_user, repository: interested_repo, kind: "briefing_generate", priority: "low")
    interested_briefing = OperatorBriefing::Briefing.create!(job: interested_job, owner_user: interested_user, repository: interested_repo, window_start: 2.days.ago, window_end: 1.day.ago)
    OperatorBriefing::Feedback.insert_all!([
      { user_id: interested_user.id, briefing_id: interested_briefing.id, sentiment: "positive", weight: 0.65, created_at: Time.current, updated_at: Time.current }
    ])
    interested_subscription = OperatorBriefing::BriefingSubscription.create!(user: interested_user, repository: interested_repo, enabled: true)
    uninterested_subscription = OperatorBriefing::BriefingSubscription.create!(user: uninterested_user, repository: uninterested_repo, enabled: true)

    migration.up

    expect(interested_subscription.reload).to be_enabled
    expect(uninterested_subscription.reload).not_to be_enabled
  end

  it "cancels active briefing work for subscriptions disabled by the backfill" do
    subscription = OperatorBriefing::BriefingSubscription.create!(user: uninterested_user, repository: uninterested_repo, enabled: true)
    job = Job.create!(user: uninterested_user, owner_user: uninterested_user, repository: uninterested_repo, kind: "briefing_generate", priority: "low")
    OperatorBriefing::Briefing.create!(job: job, owner_user: uninterested_user, repository: uninterested_repo, window_start: 2.days.ago, window_end: 1.day.ago)
    workflow = OperatorBriefing::Workflow.instantiate(job: job)
    unit = attach_work_unit(workflow, state: "blocked", blocked_reason: "provider_availability")

    migration.up

    expect(subscription.reload).not_to be_enabled
    expect(job.reload).to be_closed
    expect(unit.reload).to be_cancelled
  end
end
