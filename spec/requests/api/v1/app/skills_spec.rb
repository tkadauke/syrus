require "rails_helper"

RSpec.describe "API: /api/v1/app/repositories/:repository_id/skills", type: :request do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets", default_branch: "main") }

  def parse_body
    JSON.parse(response.body)
  end

  def stub_repo_local_tree(paths)
    client = instance_double(GithubClient)
    allow(GithubClient).to receive(:for).and_return(client)
    allow(client).to receive(:file_tree_at)
      .with("acme/widgets", "main")
      .and_return(items: paths.map { |path| { path: path, size: 10 } }, truncated: false)
    allow(client).to receive(:file_content_at).and_return(nil)
    client
  end

  # Skills.all_for's GithubClient.for fallback path (repo-local
  # discovery) is covered end-to-end at the unit level in
  # spec/services/skills_spec.rb via an injected `client:` — real
  # GithubClient objects can't be faked here (repo_local resolution
  # guards on `client.is_a?(GithubClient)`, which an RSpec double never
  # satisfies). These request specs stub Skills.all_for directly to
  # verify the controller serializes shadowing/provenance correctly.
  def resolution(name:, source:, path: nil, klass: nil, description: "Does a thing.", parameters: [])
    definition = Skills::Definition.new(name: name, description: description, parameters: Skills::ParameterSchema.normalize(parameters), instructions: "do it")
    Skills::Resolution.new(source: source, path: path, klass: klass, definition: definition)
  end

  describe "GET index" do
    it "401s with a JSON error when signed out" do
      get "/api/v1/app/repositories/#{repository.id}/skills"

      expect(response).to have_http_status(:unauthorized)
      expect(parse_body.dig("error", "code")).to eq("unauthorized")
    end

    it "lists the built-in skill when the repo has no .syrus/skills overrides" do
      stub_repo_local_tree([])
      sign_in_as(user)

      get "/api/v1/app/repositories/#{repository.id}/skills"

      expect(response).to have_http_status(:ok)
      expect(parse_body["skills"].map { |s| s["name"] }).to eq([ "debug", "explain-failing-ci", "investigate", "onboard-to-syrus" ])
      investigate = parse_body["skills"].find { |s| s["name"] == "investigate" }
      expect(investigate["source"]).to eq("built_in")
      expect(investigate["shadows_built_in"]).to eq(false)
      expect(investigate["parameters"]).to eq(
        [ { "key" => "question", "type" => "string", "required" => true, "label" => "Question",
            "options" => nil, "default" => nil, "depends_on" => nil } ]
      )
    end

    it "reflects a repo-local skill that shadows a built-in of the same name" do
      allow(Skills).to receive(:all_for).and_return(
        [ resolution(name: "investigate", source: :repo_override, path: ".syrus/skills/investigate/SKILL.md", description: "Repo override.") ]
      )

      sign_in_as(user)
      get "/api/v1/app/repositories/#{repository.id}/skills"

      expect(response).to have_http_status(:ok)
      expect(parse_body["skills"].map { |s| s["name"] }).to eq([ "investigate" ])
      investigate = parse_body["skills"].first
      expect(investigate["source"]).to eq("repo_override")
      expect(investigate["shadows_built_in"]).to eq(true)
      expect(investigate["resolved_path"]).to eq(".syrus/skills/investigate/SKILL.md")
      expect(investigate["description"]).to eq("Repo override.")
    end

    it "lists an unshadowed repo-local skill alongside the built-in" do
      allow(Skills).to receive(:all_for).and_return(
        [
          resolution(name: "audit", source: :repo_override, path: ".syrus/skills/audit/SKILL.md"),
          resolution(name: "investigate", source: :built_in, klass: Skills::Investigate)
        ]
      )

      sign_in_as(user)
      get "/api/v1/app/repositories/#{repository.id}/skills"

      expect(response).to have_http_status(:ok)
      names_and_sources = parse_body["skills"].map { |s| [ s["name"], s["source"], s["shadows_built_in"] ] }
      expect(names_and_sources).to contain_exactly(
        [ "audit", "repo_override", false ],
        [ "investigate", "built_in", false ]
      )
    end

    it "404s for a repository the signed-in user doesn't own" do
      stub_repo_local_tree([])
      other_repository = Factories.repository(user: Factories.user, owner: "other", name: "private")
      sign_in_as(user)

      get "/api/v1/app/repositories/#{other_repository.id}/skills"

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST create" do
    around do |example|
      old_runner = RunJob.agent_runner
      RunJob.agent_runner = nil
      example.run
    ensure
      RunJob.agent_runner = old_runner
    end

    it "401s with a JSON error when signed out" do
      post "/api/v1/app/repositories/#{repository.id}/skills", params: { name: "investigate", args: { question: "x" } }

      expect(response).to have_http_status(:unauthorized)
    end

    it "creates a skill-kind Job and redirects to the job page" do
      stub_repo_local_tree([])
      sign_in_as(user)

      expect {
        post "/api/v1/app/repositories/#{repository.id}/skills",
             params: { name: "investigate", args: { question: "What does the widget do?" } },
             as: :json
      }.to change(Job, :count).by(1)

      expect(response).to have_http_status(:created)
      job = Job.last
      expect(job.kind).to eq("direct")
      expect(job.skill_name).to eq("investigate")
      expect(job.skill_args).to eq({ "question" => "What does the widget do?" })
      expect(parse_body.dig("job", "skill_name")).to eq("investigate")
      expect(parse_body["redirect_to"]).to eq("/jobs/#{job.id}")
    end

    it "returns a validation error without creating a Job when required args are missing" do
      stub_repo_local_tree([])
      sign_in_as(user)

      expect {
        post "/api/v1/app/repositories/#{repository.id}/skills",
             params: { name: "investigate", args: {} },
             as: :json
      }.not_to change(Job, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(parse_body.dig("error", "message")).to match(/question/)
    end

    it "returns a validation error when the skill name doesn't resolve" do
      stub_repo_local_tree([])
      sign_in_as(user)

      expect {
        post "/api/v1/app/repositories/#{repository.id}/skills",
             params: { name: "does-not-exist", args: {} },
             as: :json
      }.not_to change(Job, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(parse_body.dig("error", "message")).to match(/could not resolve skill/)
    end

    it "rejects an agent provider the user hasn't configured" do
      stub_repo_local_tree([])
      sign_in_as(user)

      expect {
        post "/api/v1/app/repositories/#{repository.id}/skills",
             params: { name: "investigate", args: { question: "x" }, agent_provider: "codex" },
             as: :json
      }.not_to change(Job, :count)

      expect(response).to have_http_status(:unprocessable_content)
    end
  end
end
