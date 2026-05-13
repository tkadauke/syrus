require "rails_helper"

RSpec.describe "API: /api/v1/admin/runs/:run_id/transcript", type: :request do
  let(:admin) { Factories.user }
  let(:admin_token) { admin.generate_api_token! }
  let(:job) { Factories.job(user: admin) }
  let(:run) { job.initial_run }

  def auth = { "Authorization" => "Bearer #{admin_token}" }
  def parse_body = JSON.parse(response.body)

  def jsonl(*lines) = lines.map(&:to_json).join("\n") + "\n"

  before do
    ClaudeSession.create!(
      resumable: run, session_id: "abc-123",
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

  describe "GET .../transcript" do
    it "returns summary + events" do
      get "/api/v1/admin/runs/#{run.id}/transcript", headers: auth
      body = parse_body

      expect(body["run_id"]).to eq(run.id)
      expect(body["session_id"]).to eq("abc-123")

      summary = body["summary"]
      expect(summary["model"]).to eq("claude-sonnet-4-6")
      expect(summary["available_tools_at_init"]).to include("mcp__syrus__submit_summary")
      expect(summary["mcp_tool_called"]).to be false  # Bash, not the MCP tool

      kinds = body["events"].map { |e| e["kind"] }
      expect(kinds).to eq(%w[ system_init tool_use result ])
    end

    it "paginates with ?page= and ?per=" do
      get "/api/v1/admin/runs/#{run.id}/transcript", params: { per: 1, page: 2 }, headers: auth
      body = parse_body
      expect(body["pagination"]["page"]).to eq(2)
      expect(body["pagination"]["per"]).to eq(1)
      expect(body["pagination"]["total_events"]).to eq(3)
      expect(body["events"].size).to eq(1)
      expect(body["events"].first["kind"]).to eq("tool_use")
    end

    it "404s when no session was captured" do
      run.claude_session.destroy
      get "/api/v1/admin/runs/#{run.id}/transcript", headers: auth
      expect(response).to have_http_status(:not_found)
      expect(parse_body.dig("error", "code")).to eq("not_found")
    end
  end

  describe "GET .../transcript/raw" do
    it "streams the JSONL bytes" do
      get "/api/v1/admin/runs/#{run.id}/transcript/raw", headers: auth
      expect(response).to be_successful
      expect(response.content_type).to include("application/jsonl")
      expect(response.headers["Content-Disposition"]).to include("run-#{run.id}-abc-123.jsonl")
      expect(response.body).to include("system")
    end
  end
end
