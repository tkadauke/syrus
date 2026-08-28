require "rails_helper"

RSpec.describe "API: /api/v1/app/admin/worker_timeline", type: :request do
  let!(:admin) { Factories.user(admin: true) }
  let(:member) { Factories.user(admin: false) }
  let(:repository) { Factories.repository(user: admin) }
  let(:job) { Factories.job_record(user: admin, repository: repository, state: "running", issue_title: "Fix the aqueducts") }

  def parse_body = JSON.parse(response.body)

  def enable_plugin!
    PluginRecord.find_by!(name: "worker_timeline").update!(enabled: true)
  end

  describe "GET /macro" do
    it "is disabled by default (plugin disabled)" do
      sign_in_as(admin)

      get "/api/v1/app/admin/worker_timeline/macro"

      expect(response).to have_http_status(:not_found)
      expect(parse_body.dig("error", "code")).to eq("plugin_disabled")
    end

    it "rejects non-admins" do
      enable_plugin!
      sign_in_as(member)

      get "/api/v1/app/admin/worker_timeline/macro"

      expect(response).to have_http_status(:forbidden)
    end

    it "delegates to Timeline::MacroQuery with filters parsed from the shared FilterBar's q param, for an admin with the plugin enabled" do
      enable_plugin!
      sign_in_as(admin)

      other_repository = Factories.repository(user: admin)
      other_job = Factories.job_record(user: admin, repository: other_repository, state: "running")

      matching = Workflow.create!(job: job, trigger_kind: "initial", state: "running", started_at: 10.minutes.ago, worker_hostname: "worker-x")
      Workflow.create!(job: other_job, trigger_kind: "initial", state: "running", started_at: 10.minutes.ago, worker_hostname: "worker-x")

      q = Filters::QueryParam.encode(
        "and" => [
          { "field" => "repository_id", "op" => "is", "value" => repository.id },
          { "field" => "hostname", "op" => "is", "value" => "worker-x" },
          { "field" => "status", "op" => "is_one_of", "value" => [ "running" ] }
        ]
      )

      get "/api/v1/app/admin/worker_timeline/macro", params: { q: q }

      expect(response).to have_http_status(:ok)
      spans = parse_body.fetch("lanes").flat_map { |lane| lane.fetch("spans") }
      expect(spans.map { |span| span.fetch("workflow_id") }).to eq([ matching.id ])
      expect(spans.first.fetch("job_title")).to eq("Fix the aqueducts")
      expect(parse_body.fetch("filter")).to eq(Filters::QueryParam.decode(q))
    end

    it "defaults to the last 3 hours with no filters applied when no q param is given" do
      enable_plugin!
      sign_in_as(admin)

      recent = Workflow.create!(job: job, trigger_kind: "initial", state: "running", started_at: 2.hours.ago, worker_hostname: "worker-x")
      Workflow.create!(job: job, trigger_kind: "initial", state: "succeeded", started_at: 4.hours.ago, finished_at: 3.5.hours.ago, worker_hostname: "worker-x")

      get "/api/v1/app/admin/worker_timeline/macro"

      expect(response).to have_http_status(:ok)
      spans = parse_body.fetch("lanes").flat_map { |lane| lane.fetch("spans") }
      expect(spans.map { |span| span.fetch("workflow_id") }).to eq([ recent.id ])
      expect(parse_body.fetch("filter")).to eq({ "and" => [] })

      from = Time.iso8601(parse_body.dig("range", "from"))
      to = Time.iso8601(parse_body.dig("range", "to"))
      expect(to - from).to be_within(5).of(3.hours)
    end

    it "computes the time window from a within_last window chip" do
      enable_plugin!
      sign_in_as(admin)

      recent = Workflow.create!(job: job, trigger_kind: "initial", state: "running", started_at: 20.minutes.ago, worker_hostname: "worker-x")
      Workflow.create!(job: job, trigger_kind: "initial", state: "succeeded", started_at: 2.hours.ago, finished_at: 90.minutes.ago, worker_hostname: "worker-x")

      q = Filters::QueryParam.encode("and" => [ { "field" => "window", "op" => "within_last", "value" => { "n" => 30, "unit" => "minutes" } } ])

      get "/api/v1/app/admin/worker_timeline/macro", params: { q: q }

      expect(response).to have_http_status(:ok)
      spans = parse_body.fetch("lanes").flat_map { |lane| lane.fetch("spans") }
      expect(spans.map { |span| span.fetch("workflow_id") }).to eq([ recent.id ])
    end

    it "includes the filter_schema the shared FilterBar renders against" do
      enable_plugin!
      sign_in_as(admin)

      get "/api/v1/app/admin/worker_timeline/macro"

      expect(response).to have_http_status(:ok)
      expect(parse_body.fetch("filter_schema").map { |field| field.fetch("field") }).to eq(
        %w[ repository_id epic_id hostname status window ]
      )
    end
  end

  describe "GET /workflow" do
    it "is disabled by default (plugin disabled)" do
      sign_in_as(admin)

      get "/api/v1/app/admin/worker_timeline/workflow", params: { id: 1 }

      expect(response).to have_http_status(:not_found)
      expect(parse_body.dig("error", "code")).to eq("plugin_disabled")
    end

    it "rejects non-admins" do
      enable_plugin!
      sign_in_as(member)

      get "/api/v1/app/admin/worker_timeline/workflow", params: { id: 1 }

      expect(response).to have_http_status(:forbidden)
    end

    it "delegates to Timeline::WorkflowWaterfallQuery for an admin with the plugin enabled" do
      enable_plugin!
      sign_in_as(admin)

      workflow = Workflow.create!(job: job, trigger_kind: "initial", state: "running", started_at: 10.minutes.ago, worker_hostname: "worker-a")
      step = workflow.steps.create!(kind: "prepare", position: 0, state: "succeeded", started_at: 10.minutes.ago, finished_at: 9.minutes.ago)

      get "/api/v1/app/admin/worker_timeline/workflow", params: { id: workflow.id }

      expect(response).to have_http_status(:ok)
      expect(parse_body.dig("workflow", "id")).to eq(workflow.id)
      expect(parse_body.fetch("steps").map { |payload| payload.fetch("id") }).to eq([ step.id ])
    end

    it "404s for an unknown workflow id" do
      enable_plugin!
      sign_in_as(admin)

      get "/api/v1/app/admin/worker_timeline/workflow", params: { id: -1 }

      expect(response).to have_http_status(:not_found)
    end
  end
end
