require "rails_helper"

RSpec.describe Coworkers::MetricsSampler do
  include ActiveSupport::Testing::TimeHelpers

  let(:cache) { ActiveSupport::Cache::MemoryStore.new }

  around do |example|
    original = Syrus::Metrics.registry
    Syrus::Metrics.reset!
    Syrus::Metrics.declare_plugin("coworkers") do
      gauge :journaling_last_result_age_seconds, tags: %i[coworker]
      gauge :journaling_state, tags: %i[coworker state]
      gauge :journaling_last_result, tags: %i[coworker result]
      gauge :journaling_consecutive_failures, tags: %i[coworker]
      gauge :unsaved_workspace_age_seconds, tags: %i[coworker]
      gauge :unsaved_workspace_attempts, tags: %i[coworker]
      counter :spend_usd_total, tags: %i[coworker source]
    end
    example.run
  ensure
    Syrus::Metrics.instance_variable_set(:@registry, original)
  end

  before { allow(Rails).to receive(:cache).and_return(cache) }

  it "publishes fresh and stale schedule, unsaved-workspace, and mixed-source spend values by handle only" do
    now = Time.zone.parse("2026-11-19 12:00:00 UTC")
    owner = Factories.user
    repository = Factories.repository(user: owner)
    fresh = create_coworker(owner:, repository:, handle: "fresh")
    stale = create_coworker(owner:, repository:, handle: "stale")
    fresh_task = create_schedule(fresh, repository, { last_system_result_on: Date.new(2026, 11, 19), last_system_result: "journaled" })
    create_schedule(stale, repository, { state: "auto_paused", consecutive_failure_count: 3,
      last_system_result_on: Date.new(2026, 11, 15), last_system_result: "failed",
      system_result_history: [ { "date" => "2026-11-10", "result" => "journaled" }, { "date" => "2026-11-15", "result" => "failed" } ] })
    fresh_chat = fresh.coworker_chats.create!(chat_session: ChatSession.create!(user: owner, title: "Fresh"), role: "main")
    fresh_chat.update!(unsaved_workspace_branch: "coworker/fresh", unsaved_workspace_first_failed_at: now - 2.hours,
      unsaved_workspace_attempt_count: 4)
    ChatSpendEntry.create!(chat_session: fresh_chat.chat_session, user: owner, agent_provider: "codex", cost_usd: 1.25, incurred_at: now)
    job = Factories.job_with_run(repository:, user: owner, issue_number: nil, kind: "coworker_task", origin: "coworkers", origin_id: fresh.id.to_s,
      run_attrs: { cost_usd: 2.5 })

    travel_to(now) { expect(described_class.sample!).to be(true) }
    expect(described_class.refresh_gauges!).to be(true)
    rendered = Syrus::Metrics.render

    expect(rendered).to include('syrus_coworkers_journaling_state{coworker="stale",state="auto_paused"} 1')
    expect(rendered).to include('syrus_coworkers_journaling_last_result{coworker="stale",result="failed"} 1')
    expect(rendered).to include('syrus_coworkers_journaling_consecutive_failures{coworker="stale"} 3')
    expect(rendered).to include('syrus_coworkers_journaling_last_result_age_seconds{coworker="stale"} 820800')
    expect(rendered).to include('syrus_coworkers_unsaved_workspace_age_seconds{coworker="fresh"} 7200')
    expect(rendered).to include('syrus_coworkers_unsaved_workspace_attempts{coworker="fresh"} 4')
    expect(rendered).to include('syrus_coworkers_spend_usd_total{coworker="fresh",source="chat"} 1.25')
    expect(rendered).to include('syrus_coworkers_spend_usd_total{coworker="fresh",source="background_run"} 2.5')
    expect(rendered).not_to include("chat_session_id")
    series = rendered.lines.grep(/^syrus_coworkers_/)
    expect(series.size).to be <= 24
    expect(series.flat_map { |line| line[/\{([^}]*)\}/, 1].to_s.scan(/(\w+)=/).flatten }.uniq)
      .to contain_exactly("coworker", "result", "source", "state")
    expect(fresh_task).to be_present
  end

  def create_coworker(owner:, repository:, handle:)
    Coworkers::Coworker.create!(owner_user: owner, name: handle.titleize, handle:, role_summary: "QA",
      workspace_repo: "https://github.com/#{repository.owner}/#{repository.name}", state: "active")
  end

  def create_schedule(coworker, repository, attributes = {})
    ScheduledTasks::Task.create!({ user: coworker.owner_user, repository:, coworker_id: coworker.id,
      system_key: "journaling", name: "Journaling", kind: "cron", schedule_input: "30 0 * * *",
      schedule_timezone: "UTC", after_run: "quiet", pr_pileup_policy: "skip", auto_approve_mode: "never",
      state: "scheduled" }.merge(attributes))
  end
end
