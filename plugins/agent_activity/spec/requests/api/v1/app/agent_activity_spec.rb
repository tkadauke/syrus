require "rails_helper"

RSpec.describe "API: /api/v1/app/agent_activity", type: :request do
  let!(:operator) { Factories.user(admin: false) }
  let(:repository) { Factories.repository(user: operator) }

  def parse_body = JSON.parse(response.body)

  def agent_activity_job_with_run(**attrs)
    job = Factories.job_with_run(**attrs)
    record_agent_process(job.runs.last)
    job
  end

  def record_agent_process(run)
    agent = Agent.find_or_create_for!(run)
    SpawnedProcess.create!(
      agent: agent,
      run: run,
      workflow: run.workflow,
      kind: "agent",
      command: "codex exec",
      hostname: "spec-host",
      started_at: run.started_at || run.created_at,
      finished_at: run.state == "running" ? nil : (run.finished_at || run.updated_at),
      outcome: run.state == "running" ? nil : run.state
    )
  end

  describe "GET /sessions" do
    it "requires authentication" do
      get "/api/v1/app/agent_activity/sessions"

      expect(response).to have_http_status(:unauthorized)
    end

    it "returns sessions scoped to the operator's own repositories" do
      sign_in_as(operator)
      job = agent_activity_job_with_run(
        repository: repository,
        issue_title: "Fix the aqueducts",
        step_attrs: { kind: "implement" },
        run_attrs: { state: "running", agent_provider: "claude", started_at: 2.minutes.ago }
      )
      other_job = agent_activity_job_with_run(
        repository: Factories.repository,
        run_attrs: { state: "running", started_at: 2.minutes.ago }
      )

      get "/api/v1/app/agent_activity/sessions"

      expect(response).to have_http_status(:ok)
      job_ids = parse_body.fetch("sessions").map { |row| row.dig("job", "id") }
      expect(job_ids).to include(job.id)
      expect(job_ids).not_to include(other_job.id)
      expect(parse_body.fetch("running_count")).to eq(1)
    end

    it "paginates all matching sessions when the SmartFolder parameter is explicitly blank" do
      sign_in_as(operator)
      21.times do |n|
        agent_activity_job_with_run(
          repository: repository,
          issue_number: n + 1,
          step_attrs: { kind: "implement" },
          run_attrs: { state: "succeeded", started_at: (n + 1).minutes.ago, finished_at: n.minutes.ago }
        )
      end

      get "/api/v1/app/agent_activity/sessions", params: { smart_folder_id: "" }

      expect(response).to have_http_status(:ok)
      expect(parse_body.fetch("sessions").size).to eq(20)
      expect(parse_body.fetch("total")).to eq(21)
      expect(parse_body.fetch("per")).to eq(20)
    end

    it "excludes Runs whose step is not agentic" do
      sign_in_as(operator)
      agent_activity_job_with_run(
        repository: repository,
        step_attrs: { kind: "prepare" },
        run_attrs: { state: "running", started_at: 1.minute.ago }
      )

      get "/api/v1/app/agent_activity/sessions"

      expect(response).to have_http_status(:ok)
      expect(parse_body.fetch("sessions")).to be_empty
    end

    it "filters by step_kind via the shared FilterBar query tree" do
      sign_in_as(operator)
      implement_job = agent_activity_job_with_run(
        repository: repository, step_attrs: { kind: "implement" }, run_attrs: { state: "running", started_at: 2.minutes.ago }
      )
      agent_activity_job_with_run(
        repository: repository, step_attrs: { kind: "summarize" }, run_attrs: { state: "succeeded", started_at: 5.minutes.ago, finished_at: 4.minutes.ago }
      )

      q = Filters::QueryParam.encode("and" => [ { "field" => "step_kind", "op" => "is_one_of", "value" => [ "implement" ] } ])
      get "/api/v1/app/agent_activity/sessions", params: { q: q }

      expect(response).to have_http_status(:ok)
      job_ids = parse_body.fetch("sessions").map { |row| row.dig("job", "id") }
      expect(job_ids).to eq([ implement_job.id ])
    end

    it "returns SmartFolder navigation for the operator-scoped feed" do
      sign_in_as(operator)
      running_job = agent_activity_job_with_run(repository: repository, step_attrs: { kind: "implement" }, run_attrs: { state: "running", started_at: 2.minutes.ago })
      agent_activity_job_with_run(repository: repository, step_attrs: { kind: "respond" }, run_attrs: { state: "failed", started_at: 5.minutes.ago, finished_at: 4.minutes.ago })

      get "/api/v1/app/agent_activity/sessions"

      expect(response).to have_http_status(:ok)
      running_folder = SmartFolder.builtins(AgentActivity::SmartFolders::SUBJECT).find_by!(name: "Running")
      expect(parse_body.fetch("active_smart_folder_id")).to eq(running_folder.id)
      expect(parse_body.fetch("sessions").map { |row| row.dig("job", "id") }).to eq([ running_job.id ])
      folders = parse_body.fetch("smart_folders")
      expect(folders.map { |folder| folder.fetch("name") }).to include("All", "Running", "Failed")
      expect(folders.find { |folder| folder.fetch("name") == "Running" }).to include(
        "subject_type" => "agent_session",
        "count" => 1,
        "path" => a_string_matching(%r{\A/agent_activity\?smart_folder_id=\d+\z})
      )
    end

    it "returns all sessions when the SmartFolder parameter is explicitly blank" do
      sign_in_as(operator)
      running_job = agent_activity_job_with_run(repository: repository, step_attrs: { kind: "implement" }, run_attrs: { state: "running", started_at: 2.minutes.ago })
      failed_job = agent_activity_job_with_run(repository: repository, step_attrs: { kind: "respond" }, run_attrs: { state: "failed", started_at: 5.minutes.ago, finished_at: 4.minutes.ago })

      get "/api/v1/app/agent_activity/sessions", params: { smart_folder_id: "" }

      expect(response).to have_http_status(:ok)
      expect(parse_body.fetch("active_smart_folder_id")).to be_nil
      expect(parse_body.fetch("sessions").map { |row| row.dig("job", "id") }).to eq([ running_job.id, failed_job.id ])
    end

    it "combines an active SmartFolder with additional FilterBar chips" do
      sign_in_as(operator)
      running_implement = agent_activity_job_with_run(
        repository: repository, step_attrs: { kind: "implement" }, run_attrs: { state: "running", started_at: 2.minutes.ago }
      )
      agent_activity_job_with_run(repository: repository, step_attrs: { kind: "summarize" }, run_attrs: { state: "running", started_at: 3.minutes.ago })
      agent_activity_job_with_run(repository: repository, step_attrs: { kind: "implement" }, run_attrs: { state: "failed", started_at: 4.minutes.ago, finished_at: 3.minutes.ago })
      SmartFolder.ensure_builtins_for_subject!(AgentActivity::SmartFolders::SUBJECT)
      running_folder = SmartFolder.builtins(AgentActivity::SmartFolders::SUBJECT).find_by!(name: "Running")
      q = Filters::QueryParam.encode("and" => [ { "field" => "step_kind", "op" => "is_one_of", "value" => [ "implement" ] } ])

      get "/api/v1/app/agent_activity/sessions", params: { smart_folder_id: running_folder.id, q: q }

      expect(response).to have_http_status(:ok)
      expect(parse_body.fetch("active_smart_folder_id")).to eq(running_folder.id)
      job_ids = parse_body.fetch("sessions").map { |row| row.dig("job", "id") }
      expect(job_ids).to eq([ running_implement.id ])
      expect(parse_body.fetch("filter")).to eq(
        "and" => [
          { "field" => "status", "op" => "is", "value" => "running" },
          { "field" => "step_kind", "op" => "is_one_of", "value" => [ "implement" ] }
        ]
      )
    end

    it "includes the filter_schema the shared FilterBar renders against" do
      sign_in_as(operator)

      get "/api/v1/app/agent_activity/sessions"

      expect(response).to have_http_status(:ok)
      expect(parse_body.fetch("filter_schema").map { |field| field.fetch("field") }).to eq(
        %w[ repository_id job_id step_kind agent_provider status window ]
      )
      status_field = parse_body.fetch("filter_schema").find { |field| field.fetch("field") == "status" }
      expect(status_field.fetch("operators")).to include("is", "is_one_of")
    end

    it "gives each session a transcript_path scoped under the operator's own jobs route" do
      sign_in_as(operator)
      job = agent_activity_job_with_run(
        repository: repository, run_attrs: { state: "running", started_at: 1.minute.ago }
      )
      run = job.runs.last

      get "/api/v1/app/agent_activity/sessions"

      row = parse_body.fetch("sessions").first
      expect(row.fetch("transcript_path")).to eq("/api/v1/app/jobs/#{job.id}/runs/#{run.id}/artifacts")
    end
  end
end
