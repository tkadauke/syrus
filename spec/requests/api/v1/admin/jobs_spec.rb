require "rails_helper"
require "ostruct"

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

  describe "POST /jobs" do
    before { admin_token }

    it "creates a direct job for the target repository owner and starts the workflow" do
      owner = Factories.user(codex_auth_mode: "api_key", codex_api_key: "sk-test")
      repo = Factories.repository(user: owner, owner: "acme", name: "widgets", agent_provider: "codex")

      expect {
        post "/api/v1/admin/jobs",
             params: {
               job: {
                 repository: "acme/widgets",
                 title: "Invite the statues to speak",
                 prompt: "Add a small note to the README.",
                 priority: "high"
               }
             },
             headers: auth(admin_token)
      }.to change(Job, :count).by(1)
        .and have_enqueued_job(RunJob)

      expect(response).to have_http_status(:created)
      created = Job.order(:created_at).last
      expect(created.user).to eq(owner)
      expect(created.repository).to eq(repo)
      expect(created.kind).to eq("direct")
      expect(created.issue_number).to be_nil
      expect(created.issue_title).to eq("Invite the statues to speak")
      expect(created.issue_body).to eq("Add a small note to the README.")
      expect(created.priority).to eq("high")
      expect(created.agent_provider).to eq("codex")
      expect(created.runs.first.prompt).to include("Add a small note")

      body = parse_body
      expect(body["message"]).to eq("Direct job created.")
      expect(body.dig("job", "id")).to eq(created.id)
      expect(body.dig("job", "repository", "slug")).to eq("acme/widgets")
      expect(body.dig("job", "workflows").first["trigger_kind"]).to eq("initial")
    end

    it "can create a direct job under an Epic and let the Epic block execution" do
      repo = Factories.repository(user: admin, owner: "acme", name: "widgets")
      epic = Factories.epic(user: admin, repository: repo, title: "Marble administration")

      expect {
        post "/api/v1/admin/jobs",
             params: {
               job: {
                 repository_id: repo.id,
                 epic_id: epic.id,
                 prompt: "Prepare the first piece of the Epic."
               }
             },
             headers: auth(admin_token)
      }.to change(Job, :count).by(1)

      created = Job.order(:created_at).last
      expect(response).to have_http_status(:created)
      expect(created.epic).to eq(epic)
      expect(created.state).to eq("blocked_by_epic")
      expect(created.runs).to be_empty
    end

    it "rejects invalid create requests" do
      repo = Factories.repository(user: admin, owner: "acme", name: "widgets")

      aggregate_failures do
        expect {
          post "/api/v1/admin/jobs", params: { job: { repository_id: repo.id, prompt: " " } }, headers: auth(admin_token)
        }.not_to change(Job, :count)
        expect(response).to have_http_status(:unprocessable_content)
        expect(parse_body.dig("error", "message")).to include("blank")

        expect {
          post "/api/v1/admin/jobs", params: { job: { repository: "missing/repo", prompt: "Do work." } }, headers: auth(admin_token)
        }.not_to change(Job, :count)
        expect(response).to have_http_status(:unprocessable_content)
        expect(parse_body.dig("error", "message")).to include("Repository not found")

        expect {
          post "/api/v1/admin/jobs", params: { job: { repository_id: repo.id, prompt: "Do work.", priority: "imperial" } }, headers: auth(admin_token)
        }.not_to change(Job, :count)
        expect(response).to have_http_status(:unprocessable_content)
        expect(parse_body.dig("error", "message")).to include("Priority")
      end
    end
  end

  describe "payload shape" do
    before { sign_in_as(admin); admin_token }

    it "dumps job + repository + workflows + steps + runs in one shot" do
      reset_at = 10.minutes.from_now.change(usec: 0)
      admin.update!(
        gh_api_blocked_at: 2.minutes.ago,
        gh_api_blocked_reason: "API rate limit exceeded for installation ID 123",
        gh_rate_limit_remaining: 0,
        gh_rate_limit_limit: 5_000,
        gh_rate_limit_resource: "core",
        gh_rate_limit_reset_at: reset_at,
        gh_rate_limit_observed_at: Time.current
      )
      job.update!(
        pr_mergeable: true,
        pr_mergeable_checked_at: Time.current,
        github_mergeable: nil,
        github_mergeable_state: "unknown",
        mergeability_head_sha: "head123",
        mergeability_base_sha: "base123",
        mergeability_base_ref: "main",
        mergeability_checked_at: Time.current,
        local_mergeable: true,
        local_mergeable_state: "clean",
        local_mergeability_head_sha: "head123",
        local_mergeability_base_sha: "base123",
        local_mergeability_checked_at: Time.current,
        last_seen_comment_at: 5.minutes.ago,
        last_feedback_addressed_at: 6.minutes.ago,
        last_ci_handled_sha: "abc123"
      )

      # Initial workflow chain is prepare → implement → … . Set up
      # the implement step with a succeeded Run + captured agent session so
      # the assertions below match real production-shape data.
      wf = job.workflows.last
      wf.set_artifact!("test_plan", {
        steps: [ "Run bin/rspec spec/services/steps/test_plan_spec.rb" ],
        notes: "Verify admin payload exposure."
      })
      implement = wf.steps.find_by(kind: "implement")
      run = implement.runs.create!(job: job, trigger_kind: "initial",
                                   agent_provider: "codex",
                                   state: "succeeded", agent_outcome: "success",
                                   agent_turns: 7, agent_diff: "diff --git ...",
                                   started_at: 1.minute.ago, finished_at: Time.current)
      implement.update!(state: "succeeded", finished_at: Time.current)
      wf.update!(state: "succeeded", finished_at: Time.current, cleaned_up_at: Time.current)
      ClaudeSession.create!(resumable: run, provider: "codex", session_id: "abc-123",
                            transcript_jsonl: "{\"a\":1}\n{\"b\":2}\n")

      get "/api/v1/admin/jobs/#{job.id}", headers: auth(admin_token)
      body = parse_body

      expect(body["id"]).to eq(job.id)
      expect(body["state"]).to eq("queued")
      expect(body["agent_provider"]).to eq(job.agent_provider)
      expect(body["credential_mode"]).to eq(job.credential_mode)
      expect(body["stack_base"]).to eq(job.stack_base)
      expect(body["parent_job_id"]).to eq(job.parent_job_id)
      expect(body["effective_base_branch"]).to eq(job.effective_base_branch)
      expect(body["repository"]["slug"]).to eq(job.repository.slug)
      expect(body["repository"]["credential_mode"]).to eq(job.repository.credential_mode)
      expect(body["pr_mergeable"]).to be true
      expect(body["github_mergeable"]).to be_nil
      expect(body["github_mergeable_state"]).to eq("unknown")
      expect(body["mergeability_head_sha"]).to eq("head123")
      expect(body["mergeability_base_sha"]).to eq("base123")
      expect(body["mergeability_base_ref"]).to eq("main")
      expect(body["mergeability_checked_at"]).to be_present
      expect(body["local_mergeable"]).to be true
      expect(body["local_mergeable_state"]).to eq("clean")
      expect(body["local_mergeability_head_sha"]).to eq("head123")
      expect(body["local_mergeability_base_sha"]).to eq("base123")
      expect(body["local_mergeability_checked_at"]).to be_present
      expect(body["last_seen_comment_at"]).to be_present
      expect(body["last_feedback_addressed_at"]).to be_present
      expect(body["last_ci_handled_sha"]).to eq("abc123")
      expect(body["user"]).to include(
        "id" => admin.id,
        "email_address" => admin.email_address,
        "github_api_blocked" => true,
        "github_api_blocked_reason" => "API rate limit exceeded for installation ID 123"
      )
      expect(body.dig("user", "github_rate_limit")).to include(
        "remaining" => 0,
        "limit" => 5_000,
        "resource" => "core"
      )

      wf = body["workflows"].first
      expect(wf["trigger_kind"]).to eq("initial")
      expect(wf["state"]).to eq("succeeded")
      expect(wf["artifacts"]["test_plan"]).to eq(
        "steps" => [ "Run bin/rspec spec/services/steps/test_plan_spec.rb" ],
        "notes" => "Verify admin payload exposure."
      )
      expect(wf["cleaned_up_at"]).to be_present
      expect(wf["retry_available"]).to be false  # cleaned up
      expect(wf["created_at"]).to be_present
      expect(wf["updated_at"]).to be_present

      # First step in Initial workflow is now `prepare` (added in
      # the prep-step commit). Find implement explicitly to match
      # the Run we set up above.
      step = wf["steps"].find { |s| s["kind"] == "implement" }
      expect(step["state"]).to eq("succeeded")
      expect(step["created_at"]).to be_present
      expect(step["updated_at"]).to be_present

      run_payload = step["runs"].first
      expect(run_payload["agent_outcome"]).to eq("success")
      expect(run_payload["agent_turns"]).to eq(7)
      expect(run_payload["agent_diff_present"]).to be true
      expect(run_payload["agent_diff_bytes"]).to be > 0
      expect(run_payload["agent_session"]["session_id"]).to eq("abc-123")
      expect(run_payload["agent_session"]["provider"]).to eq("codex")
      expect(run_payload["agent_session"]["transcript_lines"]).to eq(2)
      expect(run_payload["agent_session"]["transcript_pruned"]).to be false
      expect(run_payload["created_at"]).to be_present
      expect(run_payload["updated_at"]).to be_present
      expect(run_payload).not_to have_key("claude_session")
    end

    it "can include a live GitHub PR snapshot without changing the default payload" do
      job.update!(pr_number: 7)
      client = instance_double(GithubClient)
      pr = OpenStruct.new(
        number: 7,
        state: "open",
        merged: false,
        mergeable: true,
        mergeable_state: "clean",
        draft: false,
        head: OpenStruct.new(ref: "syrus/issue-42", sha: "headsha", repo: OpenStruct.new(full_name: "acme/widgets")),
        base: OpenStruct.new(ref: "main", sha: "basesha", repo: OpenStruct.new(full_name: "acme/widgets"))
      )
      allow(GithubClient).to receive(:for).with(repository: job.repository, user: admin).and_return(client)
      allow(client).to receive(:pull_request).with(job.repository.slug, 7, bypass_cache: true).and_return(pr)

      get "/api/v1/admin/jobs/#{job.id}", headers: auth(admin_token)
      expect(parse_body).not_to have_key("github_pr")

      get "/api/v1/admin/jobs/#{job.id}", params: { include_github: "true" }, headers: auth(admin_token)
      expect(parse_body["github_pr"]).to include(
        "number" => 7,
        "state" => "open",
        "mergeable" => true,
        "mergeable_state" => "clean",
        "head_ref" => "syrus/issue-42",
        "head_sha" => "headsha",
        "base_ref" => "main",
        "base_sha" => "basesha"
      )
    end

    it "reports repository installation diagnostics when the job uses app credentials" do
      AppSetting.current.update!(github_app_id: "123")
      installation = Factories.installation(user: admin, github_installation_id: 131_743_025, account_login: "acme")
      repo = Factories.repository(user: admin, owner: "acme", name: "app-backed", installation: installation)
      app_job = Factories.job(user: admin, repository: repo)

      get "/api/v1/admin/jobs/#{app_job.id}", headers: auth(admin_token)
      body = parse_body

      expect(body["credential_mode"]).to eq("app")
      expect(body["repository"]).to include(
        "credential_mode" => "app",
        "app_credential_active" => true
      )
      expect(body.dig("repository", "installation")).to include(
        "github_installation_id" => 131_743_025,
        "account_login" => "acme",
        "active" => true
      )
    end

    it "tolerates a captured agent session whose transcript was pruned post-success (issue surfaced by Job 80)" do
      job_with = Factories.job(user: admin)
      run = job_with.initial_run
      run.update!(state: "succeeded")
      ClaudeSession.create!(resumable: run, session_id: "pruned-1", transcript_jsonl: nil)

      get "/api/v1/admin/jobs/#{job_with.id}", headers: auth(admin_token)
      expect(response).to be_successful

      run_payload = parse_body["workflows"]
        .flat_map { |wf| wf["steps"] }
        .flat_map { |s| s["runs"] }
        .find { |r| r.dig("agent_session", "session_id") == "pruned-1" }
      expect(run_payload["agent_session"]).to include(
        "session_id"        => "pruned-1",
        "transcript_pruned" => true,
        "transcript_bytes"  => nil,
        "transcript_lines"  => nil
      )
      expect(run_payload).not_to have_key("claude_session")
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
      expect(parse_body["jobs"].first["issue_title"]).to eq(job_124.issue_title)
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
      expect(row).to include(
        "id", "state", "kind", "credential_mode", "agent_provider", "repository",
        "issue_number", "issue_title", "pr_number", "branch_name", "pr_mergeable",
        "pr_mergeable_checked_at", "github_mergeable", "github_mergeable_state",
        "mergeability_head_sha", "mergeability_base_sha", "mergeability_base_ref",
        "mergeability_checked_at", "local_mergeable", "local_mergeable_state",
        "local_mergeability_head_sha", "local_mergeability_base_sha",
        "local_mergeability_checked_at", "last_seen_comment_at",
        "last_feedback_addressed_at", "last_ci_handled_sha"
      )
      expect(row["repository"]).to eq("acme/widgets")
      expect(row["issue_title"]).to eq(job_124.issue_title)
      expect(row["agent_provider"]).to eq(job_124.agent_provider)
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
