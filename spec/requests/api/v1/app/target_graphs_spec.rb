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

  def create_target_health(target_label:, status: "passed", fingerprint_prefix: "a", workflow: nil)
    TargetHealthRecord.create!(
      repository: repository,
      target_label: target_label,
      project_id: TargetGraph::ROOT_PROJECT_ID,
      workflow: workflow,
      commit_sha: fingerprint_prefix * 40,
      input_fingerprint: "#{fingerprint_prefix}i".ljust(64, fingerprint_prefix),
      command_fingerprint: "#{fingerprint_prefix}c".ljust(64, fingerprint_prefix),
      environment_fingerprint: "#{fingerprint_prefix}e".ljust(64, fingerprint_prefix),
      status: status,
      checked_at: Time.zone.parse("2026-09-01T12:00:00Z")
    )
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
      create_target_health(
        target_label: "//:grade/tests",
        fingerprint_prefix: "a"
      )

      get "/api/v1/app/repositories/#{repository.id}/target_graph", params: { limit: 2, offset: 1 }

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body["repository"]).to include("id" => repository.id, "slug" => "acme/widgets", "default_branch" => "main")
      expect(body["source"]).to eq("scope" => "repository", "ref" => "main")
      expect(body["tabs"]).to include(include("key" => "target_graph", "path" => "/repositories/#{repository.id}/target_graph"))
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
      expect(body["health"]).to include("scope" => "page")
      expect(body["health"]["summary"]).to include("passed" => 1)
      expect(body["filter"]).to eq("and" => [])
      expect(body["filter_schema"].map { |field| field["field"] }).to include("project_id", "label", "kind", "status", "path", "job_id", "workflow_id")
    end

    it "returns a bounded neighborhood around a focused target" do
      with_graph_checkout(graph_yaml)

      get "/api/v1/app/repositories/#{repository.id}/target_graph",
        params: { mode: "neighborhood", focus_label: "//:grade/tests", direction: "dependencies", depth: 1, limit: 2 }

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body["targets"].map { |target| target["label"] }).to contain_exactly("//:app", "//:grade/tests")
      expect(body["targets"].map { |target| target["label"] }).not_to include("//:assets")
      expect(body["page"]).to include("total" => 2, "next_offset" => nil)
      expect(body["edges"]).to include(include("from" => "//:app", "to" => "//:grade/tests", "in_window" => true))
    end

    it "can seed a neighborhood from failing target health" do
      with_graph_checkout(graph_yaml)
      create_target_health(target_label: "//:assets", status: "failed", fingerprint_prefix: "d")

      get "/api/v1/app/repositories/#{repository.id}/target_graph",
        params: { mode: "neighborhood", focus_state: "failing", direction: "dependents", depth: 1, limit: 10 }

      expect(response).to have_http_status(:ok)
      labels = parse_body["targets"].map { |target| target["label"] }
      expect(labels).to include("//:assets", "//:grade/tests")
      expect(labels).not_to include("//:app")
    end

    it "filters by kind" do
      with_graph_checkout(graph_yaml)

      get "/api/v1/app/repositories/#{repository.id}/target_graph", params: { kind: "builder" }

      expect(response).to have_http_status(:ok)
      expect(parse_body["targets"].map { |target| target["label"] }).to eq([ "//:assets" ])
    end

    it "applies FilterBar tree filters while preserving legacy plain q search" do
      with_graph_checkout(graph_yaml)
      create_target_health(target_label: "//:assets", status: "failed", fingerprint_prefix: "d")
      filter = Filters::QueryParam.encode(
        "and" => [
          { "field" => "path", "op" => "contains", "value" => "app/frontend" },
          { "field" => "status", "op" => "is", "value" => "failed" }
        ]
      )

      get "/api/v1/app/repositories/#{repository.id}/target_graph", params: { q: filter }

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body["filter"]).to eq(
        "and" => [
          { "field" => "path", "op" => "contains", "value" => "app/frontend" },
          { "field" => "status", "op" => "is", "value" => "failed" }
        ]
      )
      expect(body["targets"].map { |target| target["label"] }).to eq([ "//:assets" ])

      get "/api/v1/app/repositories/#{repository.id}/target_graph", params: { q: "grade/tests" }

      expect(response).to have_http_status(:ok)
      expect(parse_body["filter"]).to eq("and" => [])
      expect(parse_body["targets"].map { |target| target["label"] }).to eq([ "//:grade/tests" ])
    end

    it "filters targets by the workflow that produced latest health" do
      with_graph_checkout(graph_yaml)
      job = Factories.job_with_run(repository: repository, user: user)
      workflow = job.workflows.sole
      create_target_health(target_label: "//:grade/tests", workflow: workflow)
      filter = Filters::QueryParam.encode("and" => [ { "field" => "workflow_id", "op" => "equals", "value" => workflow.id } ])

      get "/api/v1/app/repositories/#{repository.id}/target_graph", params: { q: filter }

      expect(response).to have_http_status(:ok)
      expect(parse_body["targets"].map { |target| target["label"] }).to eq([ "//:grade/tests" ])
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
      create_target_health(target_label: "//:lib00", fingerprint_prefix: "b")
      create_target_health(target_label: "//:lib10", fingerprint_prefix: "c")

      get "/api/v1/app/repositories/#{repository.id}/target_graph", params: { limit: 5, offset: 10 }

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body["page"]).to include("offset" => 10, "limit" => 5, "total" => 26, "next_offset" => 15)
      expect(body["targets"].size).to eq(5)
      expect(body["targets"].first["label"]).to eq("//:lib10")
      expect(body["targets"].last["label"]).to eq("//:lib14")
      expect(body["health"]["targets"].keys).to eq([ "//:lib10" ])
      expect(body["health"]["summary"]).to include("passed" => 1)
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
            "commit_sha" => "abc1234",
            "target_health_record_refs" => [
              {
                "target_health_record_id" => 123,
                "target_label" => "//:grade/tests",
                "status" => "passed",
                "commit_sha" => "abc1234"
              }
            ]
          }
        ]
      )
      workflow.set_artifact!(
        "visual_review_preview_projects",
        [
          { "id" => "web", "label" => "Web", "path" => "app/frontend" },
          { "id" => "admin", "label" => "Admin", "path" => "app/admin" }
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
            "target_health_record_refs" => [
              include(
                "target_health_record_id" => 123,
                "target_label" => "//:grade/tests",
                "status" => "passed"
              )
            ],
            "target_fingerprints" => { "input_fingerprint" => "input" }
          )
        )
      )
      expect(body["explanations"]).to include(
        "projects" => [
          include(
            "id" => "repo",
            "selected_target_count" => 1,
            "cached_target_count" => 1
          )
        ],
        "selected_targets" => [
          include(
            "target_label" => "//:grade/tests",
            "state" => "selected",
            "reason" => "own source scope matched a changed file"
          )
        ],
        "cached_targets" => [
          include(
            "target_label" => "//:grade/tests",
            "state" => "cached",
            "target_health_record_refs" => [
              include("target_health_record_id" => 123, "status" => "passed")
            ]
          )
        ]
      )
      expect(body.dig("explanations", "ambiguous")).to include(
        include(
          "kind" => "visual_review_preview_project",
          "status" => "ambiguous",
          "choices" => [
            include("id" => "web", "label" => "Web"),
            include("id" => "admin", "label" => "Admin")
          ]
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
