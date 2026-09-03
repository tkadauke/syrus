require "rails_helper"

# The repository page's Insights tab is contributed through :repo_page_tab, so
# it appears and disappears with the plugin rather than with a feature flag.
RSpec.describe "Repository Insights tab", type: :request do
  let!(:bootstrap_admin) { Factories.user(admin: true) }
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  def enable!(enabled)
    PluginRecord.find_or_create_by!(name: "agent_insights").update!(enabled: enabled, disableable: true)
  end

  def insights_tab
    sign_in_as(user)
    get "/api/v1/app/repositories/#{repository.id}/scheduled_tasks"
    JSON.parse(response.body)["tabs"].find { |tab| tab["key"] == "agent_insights.repository" }
  end

  def create_suggestion(state: "pending")
    insight_job = Factories.job(user: user, repository: repository, kind: "agent_insight", issue_number: nil)
    AgentInsights::Suggestion.create!(
      job: insight_job,
      repository: repository,
      title: "Use caching",
      category: "performance",
      severity: "medium",
      confidence: 0.9,
      state: state
    )
  end

  it "is offered while the plugin is enabled" do
    enable!(true)

    expect(insights_tab).to include(
      "label" => "Insights",
      "path" => "/repositories/#{repository.id}/plugin/insights"
    )
  end

  it "is absent while the plugin is disabled" do
    enable!(false)

    expect(insights_tab).to be_nil
  end

  it "badges the tab with the pending suggestion count" do
    enable!(true)
    2.times { create_suggestion(state: "pending") }
    create_suggestion(state: "dismissed")

    expect(insights_tab["badge"]).to eq(2)
  end

  it "omits the badge when nothing is pending" do
    enable!(true)
    create_suggestion(state: "accepted")

    expect(insights_tab["badge"]).to be_nil
  end
end
