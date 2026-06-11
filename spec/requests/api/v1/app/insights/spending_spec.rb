require "rails_helper"

RSpec.describe "API: /api/v1/app/insights/spending", type: :request do
  def parse_body
    JSON.parse(response.body)
  end

  def set_run_cost(run, cost, created_at:)
    run.update_columns(cost_usd: cost, created_at: created_at, updated_at: created_at)
  end

  def initial_run(job)
    job.runs.find_by!(trigger_kind: "initial")
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
    ChatSession.create!(user: admin, cumulative_cost_usd: 0.75)

    sign_in_as(admin)
    get "/api/v1/app/insights/spending", params: { start_date: "2026-06-01", end_date: "2026-06-05" }

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body.dig("scope", "admin")).to eq(true)
    expect(body.dig("totals", "lifetime_usd")).to eq(4.5)
    expect(body.dig("totals", "workflow_lifetime_usd")).to eq(3.75)
    expect(body.dig("totals", "chat_lifetime_usd")).to eq(0.75)
    expect(body.dig("totals", "average_job_30d_usd")).to eq(1.875)
    expect(body.dig("totals", "average_merged_pr_30d_usd")).to eq(1.25)
    expect(body.dig("breakdowns", "repositories").map { |row| row["label"] }).to eq([ "rome/ledgers", "acme/syrus" ])
    expect(body.dig("breakdowns", "epics").first).to include(
      "label" => "Cost Senate",
      "display_number" => epic.display_number,
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
      { "date" => "2026-06-04", "total_usd" => 2.5 }
    )
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
