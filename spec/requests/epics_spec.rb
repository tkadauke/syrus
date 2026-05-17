require "rails_helper"

RSpec.describe "Epics", type: :request do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets") }

  describe "GET /epics" do
    it "requires authentication" do
      user

      get epics_path

      expect(response).to redirect_to(new_session_path)
    end

    it "renders a subject-aware chip bar and Epic SmartFolder sidebar" do
      sign_in_as(user)
      SmartFolder.ensure_epic_builtins!
      Factories.epic(user: user, repository: repo, title: "Raise the forum", state: "ready")

      get epics_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Epics")
      expect(response.body).to include("Raise the forum")
      expect(response.body).to include('data-filter-memory-subject-value="epic"')
      expect(response.body).to include("&quot;field&quot;:&quot;auto_approve_mode&quot;")
      expect(response.body).to include("Ready")
    end

    it "applies an Epic built-in SmartFolder" do
      sign_in_as(user)
      SmartFolder.ensure_epic_builtins!
      ready = Factories.epic(user: user, repository: repo, title: "Ready aqueduct", state: "ready")
      Factories.epic(user: user, repository: repo, title: "Backlog aqueduct", state: "backlog")
      folder = SmartFolder.for_subject(:epic).built_in_sidebar_order.find_by!(name: "Ready")

      get epics_path, params: { smart_folder_id: folder.id }

      expect(response.body).to include(ready.title)
      expect(response.body).not_to include("Backlog aqueduct")
    end

    it "round-trips q filters through the Epic filter" do
      sign_in_as(user)
      keep = Factories.epic(user: user, repository: repo, title: "Forum stones", state: "in_progress")
      Factories.epic(user: user, repository: repo, title: "Bathhouse tiles", state: "backlog")
      q = Filters::QueryParam.encode(
        "and" => [
          { "field" => "title", "op" => "contains", "value" => "Forum" },
          { "field" => "state", "op" => "is", "value" => "in_progress" }
        ]
      )

      get epics_path, params: { q: q }

      expect(response.body).to include(keep.title)
      expect(response.body).not_to include("Bathhouse tiles")
      expect(response.body).to include(%(value="#{q}"))
    end
  end

  describe "filter memory controller" do
    def run_filter_memory_controller(subject:, search:, stored: nil)
      script = <<~JS
        import fs from "node:fs"

        const source = fs.readFileSync("#{Rails.root.join('app/javascript/controllers/filter_memory_controller.js')}", "utf8")
          .replace('import { Controller } from "@hotwired/stimulus"', 'class Controller {}')
        const url = `data:text/javascript;base64,${Buffer.from(source).toString("base64")}`
        const mod = await import(url)
        const events = []
        const store = new Map(Object.entries(#{(stored || {}).to_json}))

        globalThis.window = {
          location: {
            search: #{search.to_json},
            pathname: #{(subject == "epic" ? "/epics" : "/dashboard/jobs").to_json},
            replace: (url) => events.push(["replace", url])
          }
        }
        globalThis.localStorage = {
          getItem: (key) => store.get(key) || null,
          setItem: (key, value) => {
            store.set(key, value)
            events.push(["set", key, value])
          },
          removeItem: (key) => {
            store.delete(key)
            events.push(["remove", key])
          }
        }

        const controller = new mod.default()
        controller.subjectValue = #{subject.to_json}
        controller.connect()
        console.log(JSON.stringify({ events, store: Object.fromEntries(store) }))
      JS

      stdout, stderr, status = Open3.capture3("node", "--input-type=module", "-e", script)
      expect(status).to be_success, stderr
      JSON.parse(stdout)
    end

    it "keys remembered filters by subject" do
      result = run_filter_memory_controller(subject: "epic", search: "?q=abc")

      expect(result["events"]).to eq([ [ "set", "syrus.filter.last:epic", "q=abc" ] ])
      expect(result["store"]).to include("syrus.filter.last:epic" => "q=abc")
      expect(result["store"]).not_to have_key("syrus.filter.last:job")
    end

    it "restores the matching subject without clobbering another subject" do
      result = run_filter_memory_controller(
        subject: "epic",
        search: "",
        stored: {
          "syrus.filter.last:job" => "q=job",
          "syrus.filter.last:epic" => "q=epic"
        }
      )

      expect(result["events"]).to eq([ [ "replace", "/epics?q=epic" ] ])
    end
  end

  describe "GET /epics/:id" do
    it "requires authentication" do
      epic = Factories.epic(user: user, repository: repo)

      get epic_path(epic)

      expect(response).to redirect_to(new_session_path)
    end

    it "shows the dependency graph expanded for small Epics" do
      sign_in_as(user)
      epic = Factories.epic(user: user, repository: repo, title: "Restore forum")
      Factories.job_record(user: user, repository: repo, epic: epic, issue_number: 10, issue_title: "Set stones")

      get epic_path(epic)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Restore forum")
      expect(response.body).to include("Dependency graph")
      expect(response.body).to include("data-controller=\"mermaid-graph\"")
      expect(response.body).to include("job_")
      expect(response.body).to match(/<details[^>]*open[^>]*>.*Dependency graph/m)
    end

    it "toggles the dependency graph between adjacent and transitive depth" do
      sign_in_as(user)
      root = Factories.epic(user: user, repository: repo, title: "Restore forum")
      middle = Factories.epic(user: user, repository: repo, title: "Repair road")
      leaf = Factories.epic(user: user, repository: repo, title: "Deliver marble")
      root_job = Factories.job_record(user: user, repository: repo, epic: root, issue_number: 20, issue_title: "Survey")
      middle_job = Factories.job_record(user: user, repository: repo, epic: middle, issue_number: 21, issue_title: "Pave")
      leaf_job = Factories.job_record(user: user, repository: repo, epic: leaf, issue_number: 22, issue_title: "Haul")
      JobDependency.create!(job: middle_job, depends_on_job: root_job, source: "manual", created_by_user: user)
      JobDependency.create!(job: leaf_job, depends_on_job: middle_job, source: "manual", created_by_user: user)

      get epic_path(root)

      expect(response.body).to include("Show all transitive dependencies")
      expect(response.body).to include("job_#{middle_job.id}")
      expect(response.body).not_to include("job_#{leaf_job.id}")

      get epic_path(root), params: { graph_depth: "transitive" }

      expect(response.body).to include("Show local dependencies")
      expect(response.body).to include("job_#{middle_job.id}")
      expect(response.body).to include("job_#{leaf_job.id}")
    end

    it "renders a drawer graph frame for Kanban cards" do
      sign_in_as(user)
      epic = Factories.epic(user: user, repository: repo, title: "Restore forum")
      Factories.job_record(user: user, repository: repo, epic: epic, issue_number: 30, issue_title: "Set stones")

      get graph_epic_path(epic), params: { drawer: 1 }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('turbo-frame id="epic_graph_drawer_body"')
      expect(response.body).to include("Dependency graph")
      expect(response.body).to include("Show all transitive dependencies")
    end

    it "does not expose another user's Epic" do
      other = Factories.user
      epic = Factories.epic(user: other)
      sign_in_as(user)

      get epic_path(epic)

      expect(response).to have_http_status(:not_found)
    end
  end
end
