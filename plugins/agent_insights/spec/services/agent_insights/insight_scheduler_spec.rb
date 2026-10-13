require "rails_helper"

RSpec.describe AgentInsights::Scheduler do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  before do
    PluginRecord.find_or_create_by!(name: "agent_insights").update!(enabled: true, disableable: true)
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

  it "rechecks for active insight jobs while holding the repository lock" do
    allow(repository).to receive(:with_lock).and_wrap_original do |method, &block|
      user.jobs.create!(
        repository: repository,
        kind: "agent_insight",
        issue_number: nil,
        issue_title: "Concurrent insight analysis",
        owner_user: user
      )
      method.call(&block)
    end

    expect {
      expect(described_class.enqueue_if_idle!(repository)).to be_nil
    }.to change { repository.jobs.where(kind: "agent_insight").count }.by(1)
  end

  it "uses the explicit user when a manual caller starts analysis" do
    manual_user = Factories.user

    job = described_class.enqueue_if_idle!(repository, user: manual_user)

    expect(job.user).to eq(manual_user)
    expect(job.owner_user).to eq(manual_user)
  end
end
