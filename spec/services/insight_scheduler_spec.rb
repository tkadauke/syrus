require "rails_helper"

RSpec.describe InsightScheduler do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  before do
    Feature.find_or_create_by!(slug: "agent_insights") do |feature|
      feature.category = "Labs"
      feature.name = "Agent Insights"
    end.update!(enabled: true)
    Feature.clear_enabled_cache!("agent_insights")
  end

  it "starts agent insight workflows through the work unit launcher" do
    job = described_class.enqueue_if_idle!(repository)

    expect(job).to be_present
    workflow = job.workflows.last
    expect(workflow.trigger_kind).to eq("agent_insight")
    expect(workflow.work_unit).to be_present
    expect(job.runs.first.trigger_kind).to eq("agent_insight")
  end
end
