require "rails_helper"

RSpec.describe Coworkers::Activity do
  let(:owner) { Factories.user }
  let(:repository) { Factories.repository(user: owner) }
  let(:coworker) do
    Coworkers::Coworker.create!(
      owner_user: owner, name: "Maya", handle: "maya-activity",
      workspace_repo: repository.remote_url
    )
  end

  before do
    PluginRecord.find_by!(name: "coworkers").update!(enabled: true)
    Syrus::PluginRegistry.clear_plugin_record_cache!
  end

  it "rolls up chat and scheduled-run spend for the week and all time" do
    main = ChatSession.create!(user: owner, cumulative_cost_usd: 1.25, title: "Maya")
    side = ChatSession.create!(user: owner, cumulative_cost_usd: 0.25, title: "Research")
    Coworkers::Chat.create!(coworker: coworker, chat_session: main, role: "main")
    Coworkers::Chat.create!(coworker: coworker, chat_session: side, role: "side")
    ChatSpendEntry.create!(chat_session: main, user: owner, incurred_at: 1.day.ago, cost_usd: 0.5, agent_provider: "codex")
    ChatSpendEntry.create!(chat_session: side, user: owner, incurred_at: 2.weeks.ago, cost_usd: 0.25, agent_provider: "codex")

    recent = coworker_run(cost: 2.0, finished_at: 2.days.ago)
    coworker_run(cost: 3.0, finished_at: 2.weeks.ago)
    JobLog.append!(run: recent, chunk: "tool", kind: "tool_call")
    JobLog.append!(run: recent, chunk: "tool", kind: "tool_call")

    payload = described_class.new(coworker: coworker, user: owner).call

    expect(payload.fetch(:spend)).to eq(week_usd: 2.5, total_usd: 6.5)
    expect(payload.fetch(:runs).find { |run| run[:id] == recent.id }).to include(
      state: "succeeded", tool_calls_count: 2, cost_usd: 2.0
    )
    expect(payload.fetch(:side_chats)).to contain_exactly(include(id: side.id, cost_usd: 0.25))
  end

  it "returns zero spend and an empty run list for a coworker with no activity" do
    expect(described_class.new(coworker: coworker, user: owner).call).to include(
      spend: { week_usd: 0.0, total_usd: 0.0 },
      runs: [],
      side_chats: []
    )
  end

  private

  def coworker_run(cost:, finished_at:)
    job = Job.create!(
      user: owner, repository: repository, kind: "coworker_task", priority: "low",
      origin: "coworkers", origin_id: coworker.id.to_s,
      issue_title: "Background task", issue_body: "Do the task."
    )
    Run.create!(
      job: job, user: owner, trigger_kind: "coworker_run", agent_provider: "codex",
      state: "succeeded", cost_usd: cost, finished_at: finished_at
    )
  end
end
