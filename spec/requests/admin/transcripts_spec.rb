require "rails_helper"

RSpec.describe "Admin transcripts", type: :request do
  let(:admin) { Factories.user }
  let(:non_admin) do
    admin  # force admin to be created first so this user is the second
    Factories.user
  end
  let(:job) { Factories.job(user: admin) }
  let(:run) { job.initial_run }

  def jsonl(*lines)
    lines.map(&:to_json).join("\n") + "\n"
  end

  describe "GET /admin/runs/:run_id/transcript" do
    before do
      ProviderSession.create!(
        resumable: run,
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

    it "redirects unauthenticated requests" do
      get "/admin/runs/#{run.id}/transcript"
      expect(response).to redirect_to(new_session_path).or redirect_to(new_user_path)
    end

    it "blocks non-admin users with an alert + redirect" do
      sign_in_as(non_admin)
      get "/admin/runs/#{run.id}/transcript"
      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to match(/admin/i)
    end

    it "serves the React transcript shell for admins" do
      sign_in_as(admin)
      get "/admin/runs/#{run.id}/transcript"
      expect(response).to be_successful
      expect(response.body).to include('id="syrus-spa-root"')
    end
  end

  it "serves the SPA shell for the retired legacy transcript GET path instead of 404ing" do
    sign_in_as(admin)
    get "/admin/runs/#{run.id}/transcript/legacy"

    expect(response).to be_successful
    expect(response.body).to include('id="syrus-spa-root"')
  end

  describe "GET /admin/runs/:run_id/transcript/download" do
    before do
      ProviderSession.create!(resumable: run, session_id: "xyz",
                            transcript_jsonl: %({"type":"result","subtype":"success"}\n))
    end

    it "sends the raw JSONL with a sensible filename" do
      sign_in_as(admin)
      get "/admin/runs/#{run.id}/transcript/download"
      expect(response).to be_successful
      expect(response.content_type).to include("application/jsonl")
      expect(response.headers["Content-Disposition"]).to include("run-#{run.id}-xyz.jsonl")
      expect(response.body).to include("result")
    end

    it "blocks non-admin users" do
      sign_in_as(non_admin)
      get "/admin/runs/#{run.id}/transcript/download"
      expect(response).to redirect_to(root_path)
    end
  end
end
