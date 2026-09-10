require "rails_helper"

RSpec.describe "API: /api/v1/app/admin/agent_activity", type: :request do
  let!(:admin) { Factories.user(admin: true) }
  let(:member) { Factories.user(admin: false) }
  let(:repository) { Factories.repository(user: Factories.user) }

  def parse_body = JSON.parse(response.body)

  describe "GET /sessions" do
    it "rejects non-admins" do
      sign_in_as(member)

      get "/api/v1/app/admin/agent_activity/sessions"

      expect(response).to have_http_status(:forbidden)
    end

    it "returns sessions across every repository, not just ones the admin belongs to" do
      sign_in_as(admin)
      job = Factories.job_with_run(
        repository: repository,
        run_attrs: { state: "running", started_at: 2.minutes.ago }
      )

      get "/api/v1/app/admin/agent_activity/sessions"

      expect(response).to have_http_status(:ok)
      job_ids = parse_body.fetch("sessions").map { |row| row.dig("job", "id") }
      expect(job_ids).to include(job.id)
    end

    it "gives each session an admin-scoped transcript_path" do
      sign_in_as(admin)
      job = Factories.job_with_run(repository: repository, run_attrs: { state: "running", started_at: 1.minute.ago })
      run = job.runs.last

      get "/api/v1/app/admin/agent_activity/sessions"

      row = parse_body.fetch("sessions").first
      expect(row.fetch("transcript_path")).to eq("/api/v1/app/admin/agent_activity/sessions/#{run.id}/artifacts")
    end

    it "returns SmartFolder navigation for the admin-wide feed" do
      sign_in_as(admin)
      Factories.job_with_run(repository: repository, step_attrs: { kind: "implement" }, run_attrs: { state: "running", started_at: 2.minutes.ago })
      Factories.job_with_run(repository: repository, step_attrs: { kind: "respond" }, run_attrs: { state: "failed", started_at: 5.minutes.ago, finished_at: 4.minutes.ago })

      get "/api/v1/app/admin/agent_activity/sessions"

      expect(response).to have_http_status(:ok)
      expect(parse_body.fetch("active_smart_folder_id")).to be_nil
      folders = parse_body.fetch("smart_folders")
      expect(folders.map { |folder| folder.fetch("name") }).to include("All", "Running", "Failed")
      expect(folders.find { |folder| folder.fetch("name") == "Running" }).to include(
        "subject_type" => "agent_session",
        "count" => 1,
        "path" => a_string_matching(%r{\A/admin/agent_activity\?smart_folder_id=\d+\z})
      )
    end

    it "combines an active SmartFolder with additional FilterBar chips" do
      sign_in_as(admin)
      running_implement = Factories.job_with_run(
        repository: repository, step_attrs: { kind: "implement" }, run_attrs: { state: "running", started_at: 2.minutes.ago }
      )
      Factories.job_with_run(repository: repository, step_attrs: { kind: "summarize" }, run_attrs: { state: "running", started_at: 3.minutes.ago })
      Factories.job_with_run(repository: repository, step_attrs: { kind: "implement" }, run_attrs: { state: "failed", started_at: 4.minutes.ago, finished_at: 3.minutes.ago })
      SmartFolder.ensure_builtins_for_subject!(AgentActivity::SmartFolders::SUBJECT)
      running_folder = SmartFolder.builtins(AgentActivity::SmartFolders::SUBJECT).find_by!(name: "Running")
      q = Filters::QueryParam.encode("and" => [ { "field" => "step_kind", "op" => "is_one_of", "value" => [ "implement" ] } ])

      get "/api/v1/app/admin/agent_activity/sessions", params: { smart_folder_id: running_folder.id, q: q }

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
  end

  describe "GET /sessions/:run_id/artifacts" do
    it "rejects non-admins" do
      sign_in_as(member)

      get "/api/v1/app/admin/agent_activity/sessions/1/artifacts"

      expect(response).to have_http_status(:forbidden)
    end

    it "returns the transcript logs for a Run on a repository the admin doesn't otherwise belong to" do
      sign_in_as(admin)
      job = Factories.job_with_run(repository: repository, run_attrs: { state: "succeeded" })
      run = job.runs.last
      run.job_logs.create!(sequence: 1, kind: "assistant_text", chunk: "Looked at the aqueducts.")

      get "/api/v1/app/admin/agent_activity/sessions/#{run.id}/artifacts"

      expect(response).to have_http_status(:ok)
      expect(parse_body.fetch("job_id")).to eq(job.id)
      expect(parse_body.fetch("logs").map { |l| l["chunk"] }).to eq([ "Looked at the aqueducts." ])
    end

    it "404s for an unknown run" do
      sign_in_as(admin)

      get "/api/v1/app/admin/agent_activity/sessions/-1/artifacts"

      expect(response).to have_http_status(:not_found)
    end
  end
end
