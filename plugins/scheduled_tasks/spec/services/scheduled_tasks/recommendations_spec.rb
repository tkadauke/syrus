require "rails_helper"

# Was App::RepositoryFeatureRecommendations#scheduled_coverage, a core method
# reaching into this plugin through repository.scheduled_tasks and
# user.cron_templates.
RSpec.describe ScheduledTasks::Recommendations do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  def task(attrs = {})
    ScheduledTasks::Task.create!({
      user: user, repository: repository, name: "Coverage", kind: "cron",
      cron_expression: "0 9 * * 1", pr_pileup_policy: "skip", prompt: "Write missing tests."
    }.merge(attrs))
  end

  it "suggests a schedule when the repository has none" do
    entries = described_class.repository_recommendations(repository: repository, user: user)

    expect(entries.map { |entry| entry[:id] }).to eq([ "scheduled_coverage" ])
    expect(entries.first[:cta][:path]).to eq("/repositories/#{repository.id}/scheduled_tasks/new")
  end

  it "says nothing once the repository has a live schedule" do
    task

    expect(described_class.repository_recommendations(repository: repository, user: user)).to be_empty
  end

  # An archived or already-fired task is history, not coverage upkeep the
  # operator still has running.
  it "still suggests one when only historical tasks exist" do
    task(name: "Archived", archived_at: 1.day.ago)
    task(name: "One-shot", kind: "one_shot", cron_expression: nil, fire_at: 1.hour.from_now).update!(state: "fired")

    expect(described_class.repository_recommendations(repository: repository, user: user).map { |e| e[:id] })
      .to eq([ "scheduled_coverage" ])
  end

  it "links through the operator's coverage template when they have one" do
    template = ScheduledTasks::CronTemplate.create!(
      user: user, name: "Increase test coverage", prompt: "Write missing tests.",
      cron_expression: "0 9 * * 1", pr_pileup_policy: "skip"
    )

    entries = described_class.repository_recommendations(repository: repository, user: user)

    expect(entries.first[:cta][:path]).to eq("/repositories/#{repository.id}/scheduled_tasks/new?from_template=#{template.id}")
  end

  it "handles a missing repository or user rather than raising into the page" do
    expect(described_class.repository_recommendations(repository: nil, user: user)).to eq([])
    expect(described_class.repository_recommendations(repository: repository, user: nil).size).to eq(1)
  end
end
