require "rails_helper"
require "tmpdir"

RSpec.describe "App API target graph inspection", type: :request do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets", default_branch: "main") }

  before { sign_in_as(user) }

  def parse_body = JSON.parse(response.body)

  def with_graph_checkout(yaml)
    allow(App::TargetGraphCheckout).to receive(:with_default_branch) do |repository:, user:, &block|
      Dir.mktmpdir("target-graph-spec-") do |dir|
        File.write(File.join(dir, ".syrus.yml"), yaml)
        block.call(Pathname.new(dir))
      end
    end
  end

  let(:graph_yaml) do
    <<~YAML
      targets:
        - name: app
          kind: library
          sources: ["app/**/*.rb"]
        - name: assets
          kind: builder
          run: npm run build
          sources: ["app/frontend/**/*"]
      grade:
        - name: tests
          run: bin/rspec
          deps: [":app", ":assets"]
    YAML
  end

  describe "GET /api/v1/app/repositories/:id/target_graph" do
    it "returns projects, targets, dependency edges, executable metadata, health, and pagination" do
      with_graph_checkout(graph_yaml)
      TargetHealthRecord.create!(
        repository: repository,
        target_label: "//:grade/tests",
        project_id: TargetGraph::ROOT_PROJECT_ID,
        commit_sha: "a" * 40,
        input_fingerprint: "b" * 64,
        command_fingerprint: "c" * 64,
        environment_fingerprint: "d" * 64,
        status: "passed",
        checked_at: Time.zone.parse("2026-09-01T12:00:00Z")
      )

      get "/api/v1/app/repositories/#{repository.id}/target_graph", params: { limit: 2, offset: 1 }

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body["repository"]).to include("id" => repository.id, "slug" => "acme/widgets", "default_branch" => "main")
      expect(body["source"]).to eq("scope" => "repository", "ref" => "main")
      expect(body["projects"]).to contain_exactly(include("id" => "repo", "target_count" => 4))
      expect(body["page"]).to include("offset" => 1, "limit" => 2, "total" => 4, "next_offset" => 3)
      expect(body["targets"].map { |target| target["label"] }).to eq([ "//:assets", "//:grade/tests" ])
      expect(body["targets"].find { |target| target["label"] == "//:assets" }).to include(
        "kind" => "builder",
        "executable" => true,
        "executable_metadata" => include("command" => "npm run build")
      )
      tests = body["targets"].find { |target| target["label"] == "//:grade/tests" }
      expect(tests["dependencies"]).to include("//:app", "//:assets")
      expect(tests["health"]).to include("status" => "passed", "commit_sha" => "a" * 40)
      expect(body["edges"]).to include(
        include("from" => "//:app", "to" => "//:grade/tests", "kind" => "dependency", "in_window" => false),
        include("from" => "//:assets", "to" => "//:grade/tests", "kind" => "dependency", "in_window" => true)
      )
      expect(body["health"]["summary"]).to include("passed" => 1)
    end

    it "filters by kind" do
      with_graph_checkout(graph_yaml)

      get "/api/v1/app/repositories/#{repository.id}/target_graph", params: { kind: "builder" }

      expect(response).to have_http_status(:ok)
      expect(parse_body["targets"].map { |target| target["label"] }).to eq([ "//:assets" ])
    end

    it "windows large graphs without returning every target" do
      large_yaml = <<~YAML
        targets:
      YAML
      25.times do |index|
        large_yaml << <<~YAML
          - name: lib#{index.to_s.rjust(2, "0")}
            kind: library
        YAML
      end
      with_graph_checkout(large_yaml)

      get "/api/v1/app/repositories/#{repository.id}/target_graph", params: { limit: 5, offset: 10 }

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body["page"]).to include("offset" => 10, "limit" => 5, "total" => 26, "next_offset" => 15)
      expect(body["targets"].size).to eq(5)
      expect(body["targets"].first["label"]).to eq("//:lib10")
      expect(body["targets"].last["label"]).to eq("//:lib14")
    end

    it "does not expose another user's repository" do
      other_repository = Factories.repository(user: Factories.user, owner: "globex", name: "private")

      get "/api/v1/app/repositories/#{other_repository.id}/target_graph"

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /api/v1/app/workflows/:workflow_id/target_graph" do
    it "returns workflow-scoped selection and cache overlays" do
      with_graph_checkout(graph_yaml)
      job = Factories.job_with_run(repository: repository, user: user)
      workflow = job.workflows.sole
      workflow.set_artifact!(
        Steps::GraderFanout::TARGET_SELECTIONS_ARTIFACT_KEY,
        [
          {
            "name" => "tests",
            "required" => true,
            "target_label" => "//:grade/tests",
            "affected" => true,
            "reason" => "own source scope matched a changed file",
            "target_fingerprints" => { "input_fingerprint" => "input" }
          }
        ]
      )
      workflow.set_artifact!(
        Steps::GraderFanout::TARGET_HEALTH_SKIPS_ARTIFACT_KEY,
        [
          {
            "name" => "tests",
            "required" => true,
            "target_label" => "//:grade/tests",
            "reason" => "latest target health record passed",
            "target_health_record_id" => 123,
            "commit_sha" => "abc1234"
          }
        ]
      )

      get "/api/v1/app/workflows/#{workflow.id}/target_graph", params: { q: "grade/tests" }

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body["workflow"]).to include("id" => workflow.id, "job_id" => job.id, "trigger_kind" => "initial")
      expect(body["targets"]).to contain_exactly(
        include(
          "label" => "//:grade/tests",
          "selection" => include(
            "state" => "cached",
            "reason" => "latest target health record passed",
            "target_health_record_id" => 123,
            "target_fingerprints" => { "input_fingerprint" => "input" }
          )
        )
      )
    end

    it "does not expose another user's workflow" do
      other_job = Factories.job_with_run(repository: Factories.repository(user: Factories.user))
      other_workflow = other_job.workflows.sole

      get "/api/v1/app/workflows/#{other_workflow.id}/target_graph"

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /api/v1/app/jobs/:job_id/target_graph" do
    it "uses the requested workflow when provided" do
      with_graph_checkout(graph_yaml)
      job = Factories.job_with_run(repository: repository, user: user)
      workflow = job.workflows.sole

      get "/api/v1/app/jobs/#{job.id}/target_graph", params: { workflow_id: workflow.id, limit: 1 }

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body["workflow"]).to include("id" => workflow.id)
      expect(body["page"]).to include("limit" => 1, "total" => 4, "next_offset" => 1)
    end
  end
end
