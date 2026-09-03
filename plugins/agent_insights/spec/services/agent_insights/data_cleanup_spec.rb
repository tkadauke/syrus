require "rails_helper"

RSpec.describe AgentInsights::DataCleanup do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  it "removes a repository's suggestions and schedule config when it is destroyed" do
    job = Factories.job(user: user, repository: repository)
    AgentInsights::Suggestion.create!(
      job: job, repository: repository, title: "Cache it",
      category: "performance", severity: "low", confidence: 0.5
    )
    AgentInsights::ScheduleConfig.create!(repository: repository, enabled: true,
                                          min_jobs_since_last_run: 1, max_jobs_since_last_run: 2)

    expect { repository.destroy! }
      .to change(AgentInsights::Suggestion, :count).by(-1)
      .and change(AgentInsights::ScheduleConfig, :count).by(-1)
  end

  it "no longer declares associations on Repository" do
    expect(Repository.reflect_on_association(:insight_suggestions)).to be_nil
    expect(Repository.reflect_on_association(:insight_schedule_config)).to be_nil
  end
end
