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
    travel_to Time.zone.parse("2026-10-28 12:00:00 UTC") do
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
      expect(payload.fetch(:jobs).find { |job| job[:id] == recent.job_id }).to include(
        slug: recent.job.slug, path: "/jobs/#{recent.job_id}", goal_summary: "Background task",
        tool_calls_count: 2, cost_usd: 2.0
      )
      expect(payload.fetch(:side_chats)).to contain_exactly(include(id: side.id, cost_usd: 0.25))
    end
  end

  it "returns zero spend and an empty run list for a coworker with no activity" do
    expect(described_class.new(coworker: coworker, user: owner).call).to include(
      spend: { week_usd: 0.0, total_usd: 0.0 },
      jobs: [],
      side_chats: []
    )
  end

  it "loads tool-call counts in one grouped query for the run collection" do
    runs = 3.times.map { coworker_run(cost: 0.25, finished_at: 1.day.ago) }
    runs.each { |run| JobLog.append!(run: run, chunk: "tool", kind: "tool_call") }

    queries = sql_queries { described_class.new(coworker: coworker, user: owner).call }
    tool_call_queries = queries.grep(/FROM ["`]job_logs["`].*kind.*GROUP BY/i)

    expect(tool_call_queries.size).to eq(1)
  end

  it "keeps the query count bounded across Jobs, Workflows, Runs, and JobLogs" do
    coworker_run(cost: 0.25, finished_at: 1.day.ago)
    one_job_queries = sql_queries { described_class.new(coworker: coworker, user: owner).call }.size
    2.times { coworker_run(cost: 0.25, finished_at: 1.day.ago) }

    three_job_queries = sql_queries { described_class.new(coworker: coworker, user: owner).call }.size

    expect(three_job_queries).to be <= one_job_queries + 1
  end

  it "loads weekly spend for a coworker collection with two aggregate queries" do
    coworkers = 3.times.map do |index|
      Coworkers::Coworker.create!(
        owner_user: owner, name: "Coworker #{index}", handle: "activity-#{index}",
        workspace_repo: repository.remote_url
      )
    end

    queries = sql_queries do
      described_class.weekly_spend_by_coworker(coworkers: coworkers, user: owner)
    end

    expect(queries.grep(/FROM ["`]chat_spend_entries["`]/i).size).to eq(1)
    expect(queries.grep(/FROM ["`]runs["`]/i).size).to eq(1)
  end

  it "paginates jobs and side chats with bounded opaque cursors" do
    runs = 51.times.map { coworker_run(cost: 0.01, finished_at: 1.day.ago) }
    chats = 51.times.map do |index|
      ChatSession.create!(user: owner, title: "Side #{index}").tap do |chat|
        Coworkers::Chat.create!(coworker: coworker, chat_session: chat, role: "side")
      end
    end

    first = described_class.new(coworker: coworker, user: owner).call
    second = described_class.new(
      coworker: coworker, user: owner,
      jobs_cursor: first.dig(:next_cursors, :jobs),
      side_chats_cursor: first.dig(:next_cursors, :side_chats)
    ).call

    expect(first.fetch(:jobs).size).to eq(50)
    expect(first.fetch(:side_chats).size).to eq(50)
    expect(second.fetch(:jobs).pluck(:id)).to eq([ runs.first.job_id ])
    expect(second.fetch(:side_chats).pluck(:id)).to eq([ chats.first.id ])
    expect(second.fetch(:next_cursors)).to eq(jobs: nil, side_chats: nil)
  end

  it "rejects malformed cursors" do
    expect {
      described_class.new(coworker: coworker, user: owner, jobs_cursor: "not-a-cursor").call
    }.to raise_error(Coworkers::Activity::InvalidCursor)
  end

  it "summarizes generic scheduled and Markdown-heavy goals without exposing markup" do
    run = coworker_run(cost: 0, finished_at: 1.day.ago)
    run.job.update_columns(issue_title: "Scheduled coworker task: Daily brief", issue_body: "# Metadata\n\nRepository: private\n\n- Brief the team on open risks. More detail follows.")

    job = described_class.new(coworker: coworker, user: owner).call.fetch(:jobs).sole

    expect(job[:goal_summary]).to eq("Brief the team on open risks.")
  end

  it "renders a job once with aggregate usage and separate workflow attempts" do
    run = coworker_run(cost: 1.25, finished_at: 1.day.ago)
    first = Workflow.create!(job: run.job, user: owner, trigger_kind: "coworker_run", state: "failed", failure_reason: "Network failed")
    second = Workflow.create!(job: run.job, user: owner, trigger_kind: "coworker_run", state: "succeeded")
    first_step = Step.create!(workflow: first, kind: "coworker_run", position: 0, state: "failed")
    second_step = Step.create!(workflow: second, kind: "coworker_run", position: 0, state: "succeeded")
    run.update!(step: first_step)
    another = Run.create!(job: run.job, step: second_step, user: owner, trigger_kind: "coworker_run", agent_provider: "codex", state: "succeeded", cost_usd: 0.75, finished_at: 1.hour.ago)
    JobLog.append!(run: another, chunk: "tool", kind: "tool_call")

    jobs = described_class.new(coworker: coworker, user: owner).call.fetch(:jobs)

    expect(jobs.size).to eq(1)
    expect(jobs.sole).to include(cost_usd: 2.0, tool_calls_count: 1)
    expect(jobs.sole.fetch(:attempts).pluck(:slug)).to eq([ first.slug, second.slug ])
  end

  it "combines state and title filters within the authorized coworker scope" do
    matching = coworker_run(cost: 0, finished_at: 1.day.ago).job
    matching.update_columns(issue_title: "Prepare launch report", state: "running")
    coworker_run(cost: 0, finished_at: 1.day.ago).job.update_columns(issue_title: "Prepare launch report", state: "closed")

    jobs = described_class.new(coworker: coworker, user: owner, filters: { state: "running", query: "launch" }).call.fetch(:jobs)

    expect(jobs.pluck(:id)).to eq([ matching.id ])
  end

  private

  def sql_queries
    queries = []
    callback = lambda do |_name, _started, _finished, _id, payload|
      queries << payload[:sql] unless payload[:cached] || payload[:name] == "SCHEMA"
    end
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    queries
  end

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
