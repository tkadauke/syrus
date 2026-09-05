require "rails_helper"

RSpec.describe "API: /api/v1/app/agent_activity", type: :request do
  let!(:operator) { Factories.user(admin: false) }
  let(:repository) { Factories.repository(user: operator) }

  def parse_body = JSON.parse(response.body)

  describe "GET /sessions" do
    it "requires authentication" do
      get "/api/v1/app/agent_activity/sessions"

      expect(response).to have_http_status(:unauthorized)
    end

    it "returns sessions scoped to the operator's own repositories" do
      sign_in_as(operator)
      job = Factories.job_with_run(
        repository: repository,
        issue_title: "Fix the aqueducts",
        step_attrs: { kind: "implement" },
        run_attrs: { state: "running", agent_provider: "claude", started_at: 2.minutes.ago }
      )
      other_job = Factories.job_with_run(
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

    it "excludes Runs whose step is not agentic" do
      sign_in_as(operator)
      Factories.job_with_run(
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
      implement_job = Factories.job_with_run(
        repository: repository, step_attrs: { kind: "implement" }, run_attrs: { state: "running", started_at: 2.minutes.ago }
      )
      Factories.job_with_run(
        repository: repository, step_attrs: { kind: "summarize" }, run_attrs: { state: "succeeded", started_at: 5.minutes.ago, finished_at: 4.minutes.ago }
      )

      q = Filters::QueryParam.encode("and" => [ { "field" => "step_kind", "op" => "is_one_of", "value" => [ "implement" ] } ])
      get "/api/v1/app/agent_activity/sessions", params: { q: q }

      expect(response).to have_http_status(:ok)
      job_ids = parse_body.fetch("sessions").map { |row| row.dig("job", "id") }
      expect(job_ids).to eq([ implement_job.id ])
    end

    it "includes the filter_schema the shared FilterBar renders against" do
      sign_in_as(operator)

      get "/api/v1/app/agent_activity/sessions"

      expect(response).to have_http_status(:ok)
      expect(parse_body.fetch("filter_schema").map { |field| field.fetch("field") }).to eq(
        %w[ repository_id job_id step_kind agent_provider status window ]
      )
    end

    it "gives each session a transcript_path scoped under the operator's own jobs route" do
      sign_in_as(operator)
      job = Factories.job_with_run(
        repository: repository, run_attrs: { state: "running", started_at: 1.minute.ago }
      )
      run = job.runs.last

      get "/api/v1/app/agent_activity/sessions"

      row = parse_body.fetch("sessions").first
      expect(row.fetch("transcript_path")).to eq("/api/v1/app/jobs/#{job.id}/runs/#{run.id}/artifacts")
    end
  end
end
