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

    it "delegates to Timeline::MacroQuery with the request's filters, for an admin with the plugin enabled" do
      enable_plugin!
      sign_in_as(admin)

      other_repository = Factories.repository(user: admin)
      other_job = Factories.job_record(user: admin, repository: other_repository, state: "running")

      matching = Workflow.create!(job: job, trigger_kind: "initial", state: "running", started_at: 10.minutes.ago, worker_hostname: "worker-x")
      Workflow.create!(job: other_job, trigger_kind: "initial", state: "running", started_at: 10.minutes.ago, worker_hostname: "worker-x")

      get "/api/v1/app/admin/worker_timeline/macro", params: { repository_id: repository.id, hostname: "worker-x", status: "running" }

      expect(response).to have_http_status(:ok)
      spans = parse_body.fetch("lanes").flat_map { |lane| lane.fetch("spans") }
      expect(spans.map { |span| span.fetch("workflow_id") }).to eq([ matching.id ])
      expect(spans.first.fetch("job_title")).to eq("Fix the aqueducts")
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

  describe "GET /filters" do
    it "is disabled by default (plugin disabled)" do
      sign_in_as(admin)

      get "/api/v1/app/admin/worker_timeline/filters"

      expect(response).to have_http_status(:not_found)
      expect(parse_body.dig("error", "code")).to eq("plugin_disabled")
    end

    it "rejects non-admins" do
      enable_plugin!
      sign_in_as(member)

      get "/api/v1/app/admin/worker_timeline/filters"

      expect(response).to have_http_status(:forbidden)
    end

    it "returns repositories, epics, statuses, and worker hostnames for an admin with the plugin enabled" do
      enable_plugin!
      sign_in_as(admin)

      repository
      epic = Factories.epic(user: admin, repository: repository)
      InstanceVersion.create!(hostname: "worker-a", role: "worker", version: "abc123", started_at: 1.hour.ago)
      InstanceVersion.create!(hostname: "web-a", role: "web", version: "abc123", started_at: 1.hour.ago)

      get "/api/v1/app/admin/worker_timeline/filters"

      expect(response).to have_http_status(:ok)
      expect(parse_body.fetch("repositories")).to include(include("id" => repository.id, "slug" => repository.slug))
      expect(parse_body.fetch("epics")).to include(include("id" => epic.id, "title" => epic.title))
      expect(parse_body.fetch("statuses")).to eq(%w[ queued running succeeded failed cancelled ])
      expect(parse_body.fetch("hostnames")).to eq([ "worker-a" ])
    end
  end
end
