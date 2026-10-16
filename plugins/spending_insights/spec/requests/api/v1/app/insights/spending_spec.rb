require "rails_helper"

RSpec.describe "API: /api/v1/app/insights/spending", type: :request do
  def parse_body
    JSON.parse(response.body)
  end

  def set_run_cost(run, cost, created_at:, finished_at: created_at)
    run.update_columns(cost_usd: cost, created_at: created_at, finished_at: finished_at, updated_at: finished_at)
  end

  it "attributes run and chat spend to completion time and excludes unfinished runs" do
    travel_to Time.zone.parse("2026-06-02 12:00:00") do
      user = Factories.user(email_address: "mine@example.com", chat_provider: "codex")
      repository = Factories.repository(user: user)
      completed = Factories.job(user: user, repository: repository, issue_number: 301)
      unfinished = Factories.job(user: user, repository: repository, issue_number: 302)
      set_run_cost(
        initial_run(completed),
        1.25,
        created_at: Time.zone.parse("2026-05-31 23:55:00"),
        finished_at: Time.zone.parse("2026-06-01 00:05:00")
      )
      initial_run(unfinished).update_columns(
        cost_usd: 9.99,
        created_at: Time.zone.parse("2026-06-01 12:00:00"),
        finished_at: nil
      )
      chat = ChatSession.create!(user: user, repository: repository, created_at: 2.months.ago)
      result = AgentInvocation::Result.new(
        turns: 1, exit_status: 0, timed_out: false, is_error: false, outcome: "success",
        final_text: "Done", session_id: "codex-session", cost_usd: 0.5
      )
      chat.record_turn_usage!(result, at: Time.zone.parse("2026-06-01 08:00:00"))

      sign_in_as(user)
      get "/api/v1/app/insights/spending", params: { start_date: "2026-06-01", end_date: "2026-06-01" }

      body = parse_body
      expect(body.dig("totals", "lifetime_usd")).to eq(1.75)
      expect(body.dig("totals", "workflow_lifetime_usd")).to eq(1.25)
      expect(body.dig("totals", "chat_lifetime_usd")).to eq(0.5)
      expect(body.fetch("top_runs")).to contain_exactly(include("id" => initial_run(completed).id))
      expect(body.fetch("trend").last).to eq("date" => "2026-06-01", "total_usd" => 1.75)
    end
  end

  def initial_run(job)
    job.runs.find_by!(trigger_kind: "initial")
  end

  def filter_query(tree)
    Filters::QueryParam.encode(tree)
  end

  it "401s with a JSON error when signed out" do
    get "/api/v1/app/insights/spending"

    expect(response).to have_http_status(:unauthorized)
    expect(parse_body).to eq(
      "error" => {
        "code" => "unauthorized",
        "message" => "Sign in to use the app API."
      }
    )
  end

  it "rolls up spending across users for admins" do
    travel_to Time.zone.local(2026, 7, 1, 12, 0, 0) do
      admin = Factories.user(admin: true, email_address: "admin@example.com")
      other_user = Factories.user(email_address: "other@example.com")
      admin_repo = Factories.repository(user: admin, owner: "acme", name: "syrus")
      other_repo = Factories.repository(user: other_user, owner: "rome", name: "ledgers")
      epic = Factories.epic(user: admin, repository: admin_repo, title: "Cost Senate")
      admin_job = Factories.job(user: admin, repository: admin_repo, issue_number: 101)
      other_job = Factories.job(user: other_user, repository: other_repo, issue_number: 202)
      admin_job.update_columns(state: "closed", closure_reason: "pr_merged", epic_id: epic.id)
      set_run_cost(initial_run(admin_job), 1.25, created_at: Time.zone.parse("2026-06-03 12:00:00"))
      set_run_cost(initial_run(other_job), 2.50, created_at: Time.zone.parse("2026-06-04 12:00:00"))
      chat = ChatSession.create!(
        user: admin,
        cumulative_cost_usd: 0.75,
        daily_cost_usd: 9.99,
        daily_cost_date: Date.new(2026, 6, 4),
        created_at: Time.zone.parse("2026-06-04 12:00:00")
      )
      ChatSpendEntry.create!(
        chat_session: chat,
        user: admin,
        incurred_at: Time.zone.parse("2026-06-04 12:00:00"),
        cost_usd: 0.75,
        agent_provider: chat.effective_chat_provider
      )

      sign_in_as(admin)
      get "/api/v1/app/insights/spending", params: { start_date: "2026-06-01", end_date: "2026-06-05" }

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body.dig("scope", "admin")).to eq(true)
      expect(body.dig("filter", "and")).to contain_exactly(
        { "field" => "created_at", "op" => "between", "value" => [ "2026-06-01", "2026-06-05" ] }
      )
      expect(body.dig("controls", "filter_schema").map { |field| field["field"] }).to include("repository_id", "user_id", "created_at", "agent_provider", "trigger_kind", "epic_id")
      expect(body.dig("totals", "lifetime_usd")).to eq(4.5)
      expect(body.dig("totals", "workflow_lifetime_usd")).to eq(3.75)
      expect(body.dig("totals", "chat_lifetime_usd")).to eq(0.75)
      expect(body.dig("totals", "average_job_30d_usd")).to eq(1.875)
      expect(body.dig("totals", "average_merged_pr_30d_usd")).to eq(1.25)
      expect(body.dig("breakdowns", "repositories").map { |row| row["label"] }).to eq([ "rome/ledgers", "acme/syrus" ])
      expect(body.dig("breakdowns", "epics").first).to include(
        "label" => "Cost Senate",
        "display_number" => epic.slug,
        "jobs_count" => 1,
        "total_usd" => 1.25,
        "average_job_usd" => 1.25
      )
      expect(body.dig("breakdowns", "users").map { |row| row["label"] }).to eq([ "other@example.com", "admin@example.com" ])
      expect(body.dig("breakdowns", "trigger_kinds").first).to include(
        "trigger_kind" => "initial",
        "jobs_count" => 2,
        "runs_count" => 2,
        "total_usd" => 3.75
      )
      expect(body.fetch("top_runs").first).to include(
        "id" => initial_run(other_job).id,
        "cost_usd" => 2.5,
        "trigger_kind" => "initial"
      )
      expect(body.fetch("trend").select { |point| point["total_usd"].positive? }).to contain_exactly(
        { "date" => "2026-06-03", "total_usd" => 1.25 },
        { "date" => "2026-06-04", "total_usd" => 3.25 }
      )
    end
  end

  it "scopes non-admin spending to the signed-in user" do
    Factories.user
    user = Factories.user(email_address: "mine@example.com")
    other_user = Factories.user(email_address: "not-mine@example.com")
    mine = Factories.job(user: user, repository: Factories.repository(user: user), issue_number: 303)
    not_mine = Factories.job(user: other_user, repository: Factories.repository(user: other_user), issue_number: 404)
    set_run_cost(initial_run(mine), 0.40, created_at: Time.zone.parse("2026-06-02 12:00:00"))
    set_run_cost(initial_run(not_mine), 9.99, created_at: Time.zone.parse("2026-06-02 12:00:00"))

    sign_in_as(user)
    get "/api/v1/app/insights/spending", params: { start_date: "2026-06-01", end_date: "2026-06-05" }

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body.dig("scope", "admin")).to eq(false)
    expect(body.dig("totals", "lifetime_usd")).to eq(0.4)
    expect(body.dig("breakdowns", "users")).to contain_exactly(
      include("label" => "mine@example.com", "total_usd" => 0.4)
    )
    expect(body.fetch("top_runs")).to contain_exactly(include("id" => initial_run(mine).id, "cost_usd" => 0.4))
  end

  it "filters workflow spending by agent provider" do
    user = Factories.user(email_address: "mine@example.com")
    repo = Factories.repository(user: user)
    claude_job = Factories.job(user: user, repository: repo, issue_number: 303, agent_provider: "claude")
    codex_job = Factories.job(user: user, repository: repo, issue_number: 404, agent_provider: "codex")
    initial_run(codex_job).update!(agent_provider: "codex")
    set_run_cost(initial_run(claude_job), 0.40, created_at: Time.zone.parse("2026-06-02 12:00:00"))
    set_run_cost(initial_run(codex_job), 0.60, created_at: Time.zone.parse("2026-06-03 12:00:00"))
    ChatSession.create!(user: user, cumulative_cost_usd: 0.25)

    sign_in_as(user)
    get "/api/v1/app/insights/spending", params: { start_date: "2026-06-01", end_date: "2026-06-05", agent_provider: "codex" }

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body.dig("filters", "agent_provider")).to eq("codex")
    expect(body.dig("filters", "agent_providers")).to eq([
      { "value" => "claude", "label" => "Claude Code" },
      { "value" => "codex", "label" => "Codex" }
    ])
    expect(body.dig("totals", "lifetime_usd")).to eq(0.6)
    expect(body.dig("totals", "workflow_lifetime_usd")).to eq(0.6)
    expect(body.dig("totals", "chat_lifetime_usd")).to eq(0.0)
    expect(body.dig("breakdowns", "repositories")).to contain_exactly(include("total_usd" => 0.6, "jobs_count" => 1))
    expect(body.fetch("top_runs")).to contain_exactly(include("id" => initial_run(codex_job).id, "agent_provider" => "codex", "cost_usd" => 0.6))
    expect(body.fetch("trend").select { |point| point["total_usd"].positive? }).to contain_exactly(
      { "date" => "2026-06-03", "total_usd" => 0.6 }
    )
  end

  it "filters workflow spending by repository and epic" do
    user = Factories.user(email_address: "mine@example.com")
    repo = Factories.repository(user: user, owner: "acme", name: "widgets")
    other_repo = Factories.repository(user: user, owner: "acme", name: "other")
    epic = Factories.epic(user: user, repository: repo, title: "Cost scoped")
    other_epic = Factories.epic(user: user, repository: other_repo, title: "Other cost")
    included = Factories.job(user: user, repository: repo, issue_number: 303)
    included.update!(epic: epic)
    same_repo_no_epic = Factories.job(user: user, repository: repo, issue_number: 304)
    other_repo_job = Factories.job(user: user, repository: other_repo, issue_number: 305)
    other_repo_job.update!(epic: other_epic)
    set_run_cost(initial_run(included), 0.40, created_at: Time.zone.parse("2026-06-02 12:00:00"))
    set_run_cost(initial_run(same_repo_no_epic), 0.60, created_at: Time.zone.parse("2026-06-03 12:00:00"))
    set_run_cost(initial_run(other_repo_job), 0.80, created_at: Time.zone.parse("2026-06-04 12:00:00"))
    ChatSession.create!(user: user, cumulative_cost_usd: 0.25)

    sign_in_as(user)
    get "/api/v1/app/insights/spending", params: {
      start_date: "2026-06-01",
      end_date: "2026-06-05",
      repository_id: repo.id,
      epic_id: epic.id
    }

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body.dig("filters", "repository_id")).to eq(repo.id)
    expect(body.dig("filters", "epic_id")).to eq(epic.id)
    expect(body.dig("totals", "lifetime_usd")).to eq(0.4)
    expect(body.fetch("top_runs")).to contain_exactly(include("id" => initial_run(included).id, "cost_usd" => 0.4))
    expect(body.fetch("trend").select { |point| point["total_usd"].positive? }).to contain_exactly(
      { "date" => "2026-06-02", "total_usd" => 0.4 }
    )
  end

  it "applies FilterBar query filters across the whole spending payload" do
    travel_to Time.zone.local(2026, 7, 1, 12, 0, 0) do
      admin = Factories.user(admin: true, email_address: "admin@example.com")
      included_user = Factories.user(email_address: "included@example.com")
      excluded_user = Factories.user(email_address: "excluded@example.com")
      repo = Factories.repository(user: included_user, owner: "acme", name: "widgets")
      other_repo = Factories.repository(user: excluded_user, owner: "acme", name: "other")
      included = Factories.job(user: included_user, repository: repo, issue_number: 303)
      excluded_repo = Factories.job(user: included_user, repository: other_repo, issue_number: 304)
      excluded_user_job = Factories.job(user: excluded_user, repository: repo, issue_number: 305)
      initial_run(included).update!(agent_provider: "codex")
      initial_run(excluded_repo).update!(agent_provider: "codex")
      initial_run(excluded_user_job).update!(agent_provider: "codex")
      set_run_cost(initial_run(included), 0.40, created_at: Time.zone.parse("2026-06-02 12:00:00"))
      set_run_cost(initial_run(excluded_repo), 0.60, created_at: Time.zone.parse("2026-06-02 12:00:00"))
      set_run_cost(initial_run(excluded_user_job), 0.80, created_at: Time.zone.parse("2026-06-02 12:00:00"))
      ChatSession.create!(user: included_user, cumulative_cost_usd: 0.25, created_at: Time.zone.parse("2026-06-02 12:00:00"))

      q = filter_query(
        "and" => [
          { "field" => "created_at", "op" => "between", "value" => [ "2026-06-01", "2026-06-05" ] },
          { "field" => "repository_id", "op" => "is", "value" => repo.id },
          { "field" => "user_id", "op" => "is", "value" => included_user.id },
          { "field" => "agent_provider", "op" => "is", "value" => "codex" }
        ]
      )

      sign_in_as(admin)
      get "/api/v1/app/insights/spending", params: { q: q }

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body.dig("filters", "repository_id")).to eq(repo.id)
      expect(body.dig("filters", "user_id")).to eq(included_user.id)
      expect(body.dig("filters", "agent_provider")).to eq("codex")
      expect(body.dig("totals", "lifetime_usd")).to eq(0.4)
      expect(body.dig("breakdowns", "repositories")).to contain_exactly(include("label" => "acme/widgets", "total_usd" => 0.4))
      expect(body.dig("breakdowns", "users")).to contain_exactly(include("label" => "included@example.com", "total_usd" => 0.4))
      expect(body.fetch("top_runs")).to contain_exactly(include("id" => initial_run(included).id, "cost_usd" => 0.4))
    end
  end

  it "keeps the default date window when FilterBar query filters omit datetime" do
    travel_to Time.zone.local(2026, 7, 1, 12, 0, 0) do
      user = Factories.user(email_address: "mine@example.com")
      repo = Factories.repository(user: user, owner: "acme", name: "widgets")
      included = Factories.job(user: user, repository: repo, issue_number: 303)
      old = Factories.job(user: user, repository: repo, issue_number: 304)
      set_run_cost(initial_run(included), 0.40, created_at: Time.zone.parse("2026-06-02 12:00:00"))
      set_run_cost(initial_run(old), 9.99, created_at: Time.zone.parse("2026-01-02 12:00:00"))

      sign_in_as(user)
      get "/api/v1/app/insights/spending", params: {
        q: filter_query("and" => [ { "field" => "repository_id", "op" => "is", "value" => repo.id } ])
      }

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body.dig("filter", "and")).to include(
        { "field" => "created_at", "op" => "between", "value" => [ "2026-04-02", "2026-07-01" ] },
        { "field" => "repository_id", "op" => "is", "value" => repo.id }
      )
      expect(body.dig("totals", "lifetime_usd")).to eq(10.39)
    end
  end

  it "keeps sections consistent when datetime is negated in a FilterBar query" do
    travel_to Time.zone.local(2026, 7, 1, 12, 0, 0) do
      user = Factories.user(email_address: "mine@example.com")
      repo = Factories.repository(user: user, owner: "acme", name: "widgets")
      excluded = Factories.job(user: user, repository: repo, issue_number: 303)
      included = Factories.job(user: user, repository: repo, issue_number: 304)
      set_run_cost(initial_run(excluded), 0.40, created_at: Time.zone.parse("2026-06-02 12:00:00"))
      set_run_cost(initial_run(included), 0.60, created_at: Time.zone.parse("2026-06-10 12:00:00"))

      sign_in_as(user)
      get "/api/v1/app/insights/spending", params: {
        q: filter_query(
          "and" => [
            { "not" => { "field" => "created_at", "op" => "between", "value" => [ "2026-06-01", "2026-06-05" ] } }
          ]
        )
      }

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body.dig("filter", "and")).to include(
        { "field" => "created_at", "op" => "between", "value" => [ "2026-04-02", "2026-07-01" ] },
        { "not" => { "field" => "created_at", "op" => "between", "value" => [ "2026-06-01", "2026-06-05" ] } }
      )
      expect(body.dig("filters", "start_date")).to eq("2026-04-02")
      expect(body.dig("filters", "end_date")).to eq("2026-07-01")
      expect(body.dig("totals", "lifetime_usd")).to eq(1.0)
      expect(body.dig("breakdowns", "repositories")).to contain_exactly(include("label" => "acme/widgets", "total_usd" => 0.6))
      expect(body.fetch("top_runs")).to contain_exactly(include("id" => initial_run(included).id, "cost_usd" => 0.6))
      expect(body.fetch("trend").select { |point| point["total_usd"].positive? }).to contain_exactly(
        { "date" => "2026-06-10", "total_usd" => 0.6 }
      )
    end
  end

  it "treats a lone start date as an open-ended filter" do
    travel_to Time.zone.local(2026, 7, 1, 12, 0, 0) do
      user = Factories.user(email_address: "mine@example.com")
      repo = Factories.repository(user: user)
      included = Factories.job(user: user, repository: repo, issue_number: 303)
      excluded = Factories.job(user: user, repository: repo, issue_number: 304)
      set_run_cost(initial_run(included), 0.40, created_at: Time.zone.parse("2027-01-10 12:00:00"))
      set_run_cost(initial_run(excluded), 0.60, created_at: Time.zone.parse("2026-12-01 12:00:00"))

      sign_in_as(user)
      get "/api/v1/app/insights/spending", params: { start_date: "2027-01-01" }

      body = parse_body
      expect(body.dig("filter", "and")).to include(
        { "field" => "created_at", "op" => "after", "value" => "2027-01-01" }
      )
      expect(body.fetch("top_runs")).to contain_exactly(include("id" => initial_run(included).id))
      expect(body.fetch("trend").select { |point| point["total_usd"].positive? }).to eq([
        { "date" => "2027-01-10", "total_usd" => 0.4 }
      ])
      expect(body.dig("totals", "lifetime_usd")).to eq(1.0)
    end
  end

  it "treats a lone end date as an open-ended filter" do
    travel_to Time.zone.local(2026, 7, 1, 12, 0, 0) do
      user = Factories.user(email_address: "mine@example.com")
      repo = Factories.repository(user: user)
      included = Factories.job(user: user, repository: repo, issue_number: 303)
      excluded = Factories.job(user: user, repository: repo, issue_number: 304)
      set_run_cost(initial_run(included), 0.40, created_at: Time.zone.parse("2025-12-01 12:00:00"))
      set_run_cost(initial_run(excluded), 0.60, created_at: Time.zone.parse("2026-02-10 12:00:00"))

      sign_in_as(user)
      get "/api/v1/app/insights/spending", params: { end_date: "2026-01-05" }

      body = parse_body
      expect(body.dig("filter", "and")).to include(
        { "field" => "created_at", "op" => "before", "value" => "2026-01-05" }
      )
      expect(body.fetch("top_runs")).to contain_exactly(include("id" => initial_run(included).id))
      expect(body.dig("totals", "lifetime_usd")).to eq(1.0)
    end
  end

  it "computes summary periods independently of the selected window" do
    travel_to Time.zone.local(2026, 7, 15, 12, 0, 0) do
      user = Factories.user(email_address: "mine@example.com")
      repo = Factories.repository(user: user)
      historical = Factories.job(user: user, repository: repo, issue_number: 303)
      current = Factories.job(user: user, repository: repo, issue_number: 304)
      set_run_cost(initial_run(historical), 0.40, created_at: Time.zone.parse("2026-05-02 12:00:00"))
      set_run_cost(initial_run(current), 0.60, created_at: Time.zone.parse("2026-07-14 12:00:00"))
      ChatSession.create!(user: user, cumulative_cost_usd: 0.25, created_at: Time.zone.parse("2026-01-01 12:00:00"))

      sign_in_as(user)
      get "/api/v1/app/insights/spending", params: { start_date: "2026-05-01", end_date: "2026-05-05" }

      body = parse_body
      expect(body.dig("totals", "week_usd")).to eq(0.6)
      expect(body.dig("totals", "month_usd")).to eq(0.6)
      expect(body.dig("totals", "workflow_lifetime_usd")).to eq(1.0)
      expect(body.dig("totals", "chat_lifetime_usd")).to eq(0.25)
      expect(body.dig("totals", "lifetime_usd")).to eq(1.25)
      expect(body.fetch("top_runs")).to contain_exactly(include("id" => initial_run(historical).id))
    end
  end

  it "ignores unsupported agent provider filters" do
    user = Factories.user(email_address: "mine@example.com")
    job = Factories.job(user: user, repository: Factories.repository(user: user), issue_number: 303, agent_provider: "claude")
    set_run_cost(initial_run(job), 0.40, created_at: Time.zone.parse("2026-06-02 12:00:00"))

    sign_in_as(user)
    get "/api/v1/app/insights/spending", params: { start_date: "2026-06-01", end_date: "2026-06-05", agent_provider: "llama" }

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body.dig("filters", "agent_provider")).to be_nil
    expect(body.dig("totals", "lifetime_usd")).to eq(0.4)
  end
end
