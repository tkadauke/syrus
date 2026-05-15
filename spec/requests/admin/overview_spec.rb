require "rails_helper"

RSpec.describe "Admin overview", type: :request do
  let(:admin) { Factories.user }
  let(:non_admin) do
    admin
    Factories.user
  end

  describe "GET /admin" do
    it "redirects unauthenticated users" do
      get "/admin"
      expect(response).to redirect_to(new_session_path).or redirect_to(new_user_path)
    end

    it "blocks non-admins" do
      sign_in_as(non_admin)
      get "/admin"
      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to match(/admin/i)
    end

    it "renders the overview for admins" do
      sign_in_as(admin)
      get "/admin"
      expect(response).to be_successful
      expect(response.body).to include("Admin overview")
      expect(response.body).to include("Active runs")
      expect(response.body).to include("Workers")
      expect(response.body).to include("Agent session capture")
      expect(response.body).not_to include("Claude session capture")
      expect(response.body).to include("Stuck things")
    end

    it "counts Codex-backed captured sessions as agent sessions" do
      sign_in_as(admin)
      job = Factories.job(user: admin)
      run = job.initial_run
      run.update!(state: "succeeded", agent_provider: "codex", finished_at: Time.current)
      run.step.update!(kind: "implement")
      ClaudeSession.create!(resumable: run, provider: "codex",
                            session_id: "codex-thread", transcript_jsonl: "{}\n")

      get "/admin"

      expect(response.body).to include("Agent session capture")
      expect(response.body).to include("100%")
      expect(response.body).to include("1 of 1 agentic runs (24h)")
      expect(response.body).not_to include("Claude session capture")
    end

    it "wires the auto-refresh Stimulus controller" do
      sign_in_as(admin)
      get "/admin"
      expect(response.body).to include('data-controller="auto-refresh"')
      expect(response.body).to include('data-auto-refresh-interval-value="30"')
    end

    it "links each tile to its drill-down page" do
      sign_in_as(admin)
      get "/admin"
      expect(response.body).to include('href="/admin/queue/active"')
      expect(response.body).to include('href="/admin/queue/pending"')
      expect(response.body).to include('href="/admin/queue/workers"')
      expect(response.body).to include('href="/admin/queue/recurring"')
      expect(response.body).to include('href="/admin/queue/failed"')
    end

    it "flags a Run silent past ADMIN_STUCK_THRESHOLD as :warn (stale_heartbeat)" do
      sign_in_as(admin)
      job = Factories.job(user: admin)
      run = job.initial_run
      # Past the admin warn threshold (5 min) but inside the
      # reaper threshold (30 min) — so it's "concerning" but the
      # reaper would still get it.
      run.update_columns(state: "running",
                         started_at: 10.minutes.ago,
                         last_heartbeat_at: 10.minutes.ago)

      get "/admin"
      expect(response.body).to include("stale_heartbeat")
      expect(response.body).to include("Run ##{run.id}")
    end

    it "escalates to :alarm (reaper_starved) when a Run is silent past the reaper threshold" do
      sign_in_as(admin)
      job = Factories.job(user: admin)
      run = job.initial_run
      # Past the reaper's STALE_HEARTBEAT_THRESHOLD (30 min) yet
      # still `running` ⇒ the reaper isn't reaping ⇒ alarm.
      run.update_columns(state: "running",
                         started_at: (Run::STALE_HEARTBEAT_THRESHOLD + 5.minutes).ago,
                         last_heartbeat_at: (Run::STALE_HEARTBEAT_THRESHOLD + 5.minutes).ago)

      get "/admin"
      expect(response.body).to include("reaper_starved")
      expect(response.body).to match(/ReapStaleRunsJob may be starved/)
    end

    it "treats a never-logged Run (last_heartbeat_at IS NULL) the same as stale" do
      sign_in_as(admin)
      job = Factories.job(user: admin)
      run = job.initial_run
      run.update_columns(state: "running",
                         started_at: 10.minutes.ago,
                         last_heartbeat_at: nil)

      get "/admin"
      expect(response.body).to include("stale_heartbeat")
    end

    it "doesn't flag a Run with a fresh heartbeat" do
      sign_in_as(admin)
      job = Factories.job(user: admin)
      run = job.initial_run
      run.update_columns(state: "running",
                         started_at: 30.seconds.ago,
                         last_heartbeat_at: 30.seconds.ago)

      get "/admin"
      expect(response.body).not_to include("stale_heartbeat")
      expect(response.body).not_to include("reaper_starved")
    end
  end
end
