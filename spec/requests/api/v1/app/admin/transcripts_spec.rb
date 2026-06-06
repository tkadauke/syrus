require "rails_helper"

RSpec.describe "API: /api/v1/app/admin/runs/:run_id/transcript", type: :request do
  let(:admin) { Factories.user }
  let(:non_admin) do
    admin
    Factories.user
  end
  let(:job) { Factories.job(user: admin) }
  let(:run) { job.initial_run }

  def parse_body
    JSON.parse(response.body)
  end

  def jsonl(*lines)
    lines.map(&:to_json).join("\n") + "\n"
  end

  before do
    ClaudeSession.create!(
      resumable: run,
      provider: "codex",
      session_id: "abc-123",
      transcript_jsonl: jsonl(
        { "type" => "system", "subtype" => "init", "model" => "claude-sonnet-4-6",
          "cwd" => "/x", "tools" => [ "Bash", "mcp__syrus__submit_summary" ],
          "session_id" => "abc-123" },
        { "type" => "assistant", "message" => { "content" => [
          { "type" => "tool_use", "name" => "Bash", "input" => { "command" => "ls" }, "id" => "u1" }
        ] } },
        { "type" => "result", "subtype" => "success", "num_turns" => 1,
          "duration_ms" => 200, "total_cost_usd" => 0.01, "is_error" => false }
      )
    )
  end

  it "401s with a JSON error when signed out" do
    get "/api/v1/app/admin/runs/#{run.id}/transcript"

    expect(response).to have_http_status(:unauthorized)
    expect(parse_body.dig("error", "code")).to eq("unauthorized")
  end

  it "403s with a JSON error for non-admin users" do
    sign_in_as(non_admin)

    get "/api/v1/app/admin/runs/#{run.id}/transcript"

    expect(response).to have_http_status(:forbidden)
    expect(parse_body.dig("error", "code")).to eq("forbidden")
  end

  it "returns summary and paginated events for admin users" do
    sign_in_as(admin)

    get "/api/v1/app/admin/runs/#{run.id}/transcript", params: { per: 1, page: 2 }

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body).to include(
      "run_id" => run.id,
      "job_id" => job.id,
      "session_id" => "abc-123"
    )
    expect(body["summary"]).to include(
      "model" => "claude-sonnet-4-6",
      "available_tools_at_init" => [ "Bash", "mcp__syrus__submit_summary" ]
    )
    expect(body["pagination"]).to include(
      "page" => 2,
      "per" => 1,
      "total_events" => 3
    )
    expect(body["events"].first["kind"]).to eq("tool_use")
  end

  it "returns JobLog fallback events when no session was captured" do
    sign_in_as(admin)
    run.claude_session.destroy
    JobLog.append!(run: run, chunk: "fallback transcript row", kind: "system")

    get "/api/v1/app/admin/runs/#{run.id}/transcript"

    expect(response).to have_http_status(:ok)
    expect(parse_body["session_id"]).to be_nil
    expect(parse_body["events"].map { |event| event["kind"] }).to eq([ "job_log" ])
    expect(parse_body["events"].first["data"]).to include(
      "kind" => "system",
      "text" => "fallback transcript row"
    )
  end
end
