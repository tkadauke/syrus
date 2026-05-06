require "rails_helper"

RSpec.describe "API: /api/v1/admin/jobs/:id", type: :request do
  let(:admin) { Factories.user }
  let(:non_admin) { admin; Factories.user }  # second user → not admin
  let(:admin_token) { admin.generate_api_token! }
  let(:non_admin_token) { non_admin.generate_api_token! }

  let(:job) { Factories.job(user: admin) }

  def auth(token) = { "Authorization" => "Bearer #{token}" }
  def parse_body  = JSON.parse(response.body)

  describe "auth" do
    it "401s without an Authorization header" do
      get "/api/v1/admin/jobs/#{job.id}"
      expect(response).to have_http_status(:unauthorized)
      expect(parse_body.dig("error", "code")).to eq("unauthorized")
    end

    it "401s with a bogus token" do
      get "/api/v1/admin/jobs/#{job.id}", headers: auth("syrus_bogus")
      expect(response).to have_http_status(:unauthorized)
    end

    it "403s when the token belongs to a non-admin user" do
      get "/api/v1/admin/jobs/#{job.id}", headers: auth(non_admin_token)
      expect(response).to have_http_status(:forbidden)
      expect(parse_body.dig("error", "code")).to eq("forbidden")
    end

    it "200s with an admin token" do
      get "/api/v1/admin/jobs/#{job.id}", headers: auth(admin_token)
      expect(response).to have_http_status(:ok)
      expect(response.content_type).to include("application/json")
    end
  end

  describe "payload shape" do
    before { sign_in_as(admin); admin_token }

    it "dumps job + repository + workflows + steps + runs in one shot" do
      # Initial workflow chain is prepare → implement → … . Set up
      # the implement step with a succeeded Run + ClaudeSession so
      # the assertions below match real production-shape data.
      wf = job.workflows.last
      implement = wf.steps.find_by(kind: "implement")
      run = implement.runs.create!(job: job, trigger_kind: "initial",
                                   state: "succeeded", agent_outcome: "success",
                                   agent_turns: 7, agent_diff: "diff --git ...",
                                   started_at: 1.minute.ago, finished_at: Time.current)
      implement.update!(state: "succeeded", finished_at: Time.current)
      wf.update!(state: "succeeded", finished_at: Time.current, cleaned_up_at: Time.current)
      ClaudeSession.create!(run: run, session_id: "abc-123",
                            transcript_jsonl: "{\"a\":1}\n{\"b\":2}\n")

      get "/api/v1/admin/jobs/#{job.id}", headers: auth(admin_token)
      body = parse_body

      expect(body["id"]).to eq(job.id)
      expect(body["state"]).to eq("open")
      expect(body["repository"]["slug"]).to eq(job.repository.slug)

      wf = body["workflows"].first
      expect(wf["trigger_kind"]).to eq("initial")
      expect(wf["state"]).to eq("succeeded")
      expect(wf["cleaned_up_at"]).to be_present
      expect(wf["retry_available"]).to be false  # cleaned up

      # First step in Initial workflow is now `prepare` (added in
      # the prep-step commit). Find implement explicitly to match
      # the Run we set up above.
      step = wf["steps"].find { |s| s["kind"] == "implement" }
      expect(step["state"]).to eq("succeeded")

      run_payload = step["runs"].first
      expect(run_payload["agent_outcome"]).to eq("success")
      expect(run_payload["agent_turns"]).to eq(7)
      expect(run_payload["agent_diff_present"]).to be true
      expect(run_payload["agent_diff_bytes"]).to be > 0
      expect(run_payload["claude_session"]["session_id"]).to eq("abc-123")
      expect(run_payload["claude_session"]["transcript_lines"]).to eq(2)
      expect(run_payload["claude_session"]["transcript_pruned"]).to be false
    end

    it "tolerates a ClaudeSession whose transcript was pruned post-success (issue surfaced by Job 80)" do
      job_with = Factories.job(user: admin)
      run = job_with.initial_run
      run.update!(state: "succeeded")
      ClaudeSession.create!(run: run, session_id: "pruned-1", transcript_jsonl: nil)

      get "/api/v1/admin/jobs/#{job_with.id}", headers: auth(admin_token)
      expect(response).to be_successful

      run_payload = parse_body["workflows"]
        .flat_map { |wf| wf["steps"] }
        .flat_map { |s| s["runs"] }
        .find { |r| r.dig("claude_session", "session_id") == "pruned-1" }
      expect(run_payload["claude_session"]).to include(
        "session_id"        => "pruned-1",
        "transcript_pruned" => true,
        "transcript_bytes"  => nil,
        "transcript_lines"  => nil
      )
    end

    it "swaps in an error envelope when a single Run's serializer raises (others still render)" do
      job_with = Factories.job(user: admin)
      good_run = job_with.initial_run
      good_run.update!(state: "succeeded", agent_turns: 5)

      # Force serialize_run to blow up by stubbing one specific Run
      # to raise on a leaf attribute access.
      allow_any_instance_of(Run).to receive(:agent_diff).and_wrap_original do |original, *args|
        if original.receiver.id == good_run.id
          raise "boom — simulated bad row"
        else
          original.call(*args)
        end
      end

      get "/api/v1/admin/jobs/#{job_with.id}", headers: auth(admin_token)
      expect(response).to be_successful, "expected 200, got #{response.status}: #{response.body[0, 400]}"

      run_payload = parse_body["workflows"]
        .flat_map { |wf| wf["steps"] }
        .flat_map { |s| s["runs"] }
        .find { |r| r["id"] == good_run.id }
      expect(run_payload).to include(
        "id"                 => good_run.id,
        "error_serializing"  => /boom — simulated bad row/
      )
      # Sibling fields don't appear (the whole hash was replaced
      # by the error envelope), but the Job + Workflows + Steps
      # surrounding it still render.
      expect(parse_body["state"]).to be_present
      expect(parse_body["workflows"].first["state"]).to be_present
    end

    it "404s for an unknown job id with the structured error envelope" do
      get "/api/v1/admin/jobs/99999", headers: auth(admin_token)
      expect(response).to have_http_status(:not_found)
      expect(parse_body.dig("error", "code")).to eq("not_found")
    end
  end

  describe "GET /api/v1/admin/jobs (compact list with filters)" do
    let!(:repo_a) { Factories.repository(user: admin, owner: "acme", name: "widgets") }
    let!(:repo_b) { Factories.repository(user: admin, owner: "acme", name: "thingies") }

    let!(:job_124) { Factories.job(user: admin, repository: repo_a, issue_number: 124, pr_number: 144) }
    let!(:job_125) { Factories.job(user: admin, repository: repo_a, issue_number: 125, pr_number: 146) }
    let!(:job_b)   { Factories.job(user: admin, repository: repo_b, issue_number: 124) }  # diff repo, same issue#

    it "filters by pr_number" do
      get "/api/v1/admin/jobs", params: { pr_number: 144 }, headers: auth(admin_token)
      expect(response).to be_successful
      ids = parse_body["jobs"].map { |j| j["id"] }
      expect(ids).to contain_exactly(job_124.id)
    end

    it "filters by issue_number across repos (caller likely wants to narrow with ?repo=)" do
      get "/api/v1/admin/jobs", params: { issue_number: 124 }, headers: auth(admin_token)
      ids = parse_body["jobs"].map { |j| j["id"] }
      expect(ids).to contain_exactly(job_124.id, job_b.id)
    end

    it "narrows by repo slug" do
      get "/api/v1/admin/jobs", params: { issue_number: 124, repo: "acme/widgets" }, headers: auth(admin_token)
      ids = parse_body["jobs"].map { |j| j["id"] }
      expect(ids).to contain_exactly(job_124.id)
    end

    it "filters by state" do
      job_124.close!
      job_124.save!
      get "/api/v1/admin/jobs", params: { state: "open" }, headers: auth(admin_token)
      ids = parse_body["jobs"].map { |j| j["id"] }
      expect(ids).to include(job_125.id, job_b.id)
      expect(ids).not_to include(job_124.id)
    end

    it "returns a compact shape — repository slug, issue/pr/branch, no nested workflows" do
      get "/api/v1/admin/jobs", params: { pr_number: 144 }, headers: auth(admin_token)
      row = parse_body["jobs"].first
      expect(row).to include("id", "state", "kind", "repository", "issue_number", "pr_number", "branch_name")
      expect(row["repository"]).to eq("acme/widgets")
      expect(row).not_to have_key("workflows")
    end

    it "401s without a token" do
      get "/api/v1/admin/jobs"
      expect(response).to have_http_status(:unauthorized)
    end

    it "403s for non-admin users" do
      get "/api/v1/admin/jobs", headers: auth(non_admin_token)
      expect(response).to have_http_status(:forbidden)
    end

    describe "?user= filter (email substring)" do
      let!(:other_user) { Factories.user(email_address: "ophelia@example.com") }
      let!(:other_job) do
        repo = Factories.repository(user: other_user, owner: "globex", name: "stuff")
        Factories.job(user: other_user, repository: repo, issue_number: 50)
      end

      it "narrows to Jobs whose user's email matches the substring" do
        get "/api/v1/admin/jobs", params: { user: "ophelia" }, headers: auth(admin_token)
        ids = parse_body["jobs"].map { |j| j["id"] }
        expect(ids).to contain_exactly(other_job.id)
      end
    end

    describe "?has_active_workflow=true" do
      it "narrows to Jobs with a queued or running workflow" do
        # job_124 has the auto-created Initial workflow from Factories.job;
        # mark it terminal so we can tell which Jobs surface.
        job_124.workflows.update_all(state: "succeeded", finished_at: Time.current)

        Workflow.create!(job: job_125, trigger_kind: "rebase", state: "running")

        get "/api/v1/admin/jobs", params: { has_active_workflow: "true" }, headers: auth(admin_token)
        ids = parse_body["jobs"].map { |j| j["id"] }
        expect(ids).to include(job_125.id)
        expect(ids).not_to include(job_124.id)
      end
    end

    describe "?failed_in_last_24h=true" do
      # Each Job auto-creates an `initial` workflow via after_create_commit;
      # to make the "latest workflow" what we set up here, force the
      # `retry` workflow to be the most recent for that job.
      def add_retry_workflow(job, state:, finished_at:, age_offset: 1.minute)
        # `created_at: 1.minute.from_now` (or any future time) guarantees
        # this workflow is later than the auto-Initial that fired during
        # Factories.job, regardless of test wallclock.
        Workflow.create!(job: job, trigger_kind: "retry",
                         state: state, finished_at: finished_at,
                         created_at: age_offset.from_now)
      end

      it "narrows to Jobs whose LATEST workflow failed within the window" do
        add_retry_workflow(job_124, state: "failed",    finished_at: 30.minutes.ago)
        add_retry_workflow(job_125, state: "succeeded", finished_at: 30.minutes.ago)

        get "/api/v1/admin/jobs", params: { failed_in_last_24h: "true" }, headers: auth(admin_token)
        ids = parse_body["jobs"].map { |j| j["id"] }
        expect(ids).to include(job_124.id)
        expect(ids).not_to include(job_125.id)
      end

      it "ignores Jobs whose LATEST workflow succeeded even if an earlier one failed (don't re-surface fixed work)" do
        add_retry_workflow(job_124, state: "failed",    finished_at: 90.minutes.ago, age_offset: 1.minute)
        add_retry_workflow(job_124, state: "succeeded", finished_at: 30.minutes.ago, age_offset: 2.minutes)  # newer

        get "/api/v1/admin/jobs", params: { failed_in_last_24h: "true" }, headers: auth(admin_token)
        ids = parse_body["jobs"].map { |j| j["id"] }
        expect(ids).not_to include(job_124.id)
      end

      it "ignores Jobs whose latest failed workflow is older than the window" do
        Workflow.create!(job: job_124, trigger_kind: "retry",
                          state: "failed", finished_at: 2.days.ago, created_at: 2.days.ago)

        get "/api/v1/admin/jobs", params: { failed_in_last_24h: "true" }, headers: auth(admin_token)
        ids = parse_body["jobs"].map { |j| j["id"] }
        expect(ids).not_to include(job_124.id)
      end
    end
  end
end
