require "rails_helper"
require "cgi"

RSpec.describe "Epics", type: :request do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets") }

  describe "GET /epics" do
    it "redirects to the root Epic dashboard subject" do
      get epics_path

      expect(response).to have_http_status(:found)
      expect(response).to redirect_to("/?subject=epic")
    end

    it "preserves query params in the compatibility redirect" do
      q = Filters::QueryParam.encode("and" => [ { "field" => "state", "op" => "is", "value" => "ready" } ])

      get epics_path, params: { q: q, smart_folder_id: "12" }

      expect(response).to have_http_status(:found)
      expect(response.location).to eq("http://www.example.com/?subject=epic&q=#{CGI.escape(q)}&smart_folder_id=12")
    end
  end

  describe "PATCH /epics/:id/archive" do
    it "archives an active Epic and redirects to the Epic dashboard" do
      sign_in_as(user)
      epic = Factories.epic(user: user, repository: repo, state: "ready")

      patch archive_epic_path(epic)

      expect(response).to redirect_to(epics_path)
      expect(flash[:notice]).to eq("Epic archived.")
      expect(epic.reload).to be_archived
    end

    it "returns 404 for another user's Epic" do
      sign_in_as(user)
      other_user = Factories.user
      other_repo = Factories.repository(user: other_user)
      epic = Factories.epic(user: other_user, repository: other_repo, state: "ready")

      patch archive_epic_path(epic)

      expect(response).to have_http_status(:not_found)
      expect(epic.reload).to be_ready
    end

    it "redirects neutrally when the Epic is already archived" do
      sign_in_as(user)
      epic = Factories.epic(user: user, repository: repo, state: "ready")
      epic.archive!

      patch archive_epic_path(epic)

      expect(response).to redirect_to(epics_path)
      expect(flash[:notice]).to eq("Epic already archived.")
      expect(epic.reload).to be_archived
    end
  end

  describe "GET /?subject=epic&view=list" do
    it "renders a subject-aware chip bar and Epic SmartFolder sidebar" do
      sign_in_as(user)
      SmartFolder.ensure_epic_builtins!
      Factories.epic(user: user, repository: repo, title: "Raise the forum", state: "ready")

      get root_path, params: { subject: "epic", view: "list" }

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

      get root_path, params: { subject: "epic", view: "list", smart_folder_id: folder.id }

      expect(response.body).to include(ready.title)
      expect(response.body).not_to include("Backlog aqueduct")
      expect(response.body).not_to include("Showing smart folder")
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

      get root_path, params: { subject: "epic", view: "list", q: q }

      expect(response.body).to include(keep.title)
      expect(response.body).not_to include("Bathhouse tiles")
      expect(response.body).to include(%(value="#{q}"))
    end

    it "renders a save form for non-empty Epic filters" do
      sign_in_as(user)
      q = Filters::QueryParam.encode(
        "and" => [
          { "field" => "state", "op" => "is", "value" => "ready" }
        ]
      )

      get root_path, params: { subject: "epic", view: "list", q: q }

      document = Nokogiri::HTML(response.body)
      form = document.at_css("form[action='#{smart_folders_path}']")

      expect(form).to be_present
      expect(form.at_css("input[name='subject_type'][value='epic']")).to be_present
      expect(form.at_css("input[name='filter']")).to be_present
      expect(form.text).to include("Save current filter as")
    end

    it "hides archived Epics by default but shows them through the Archived folder" do
      sign_in_as(user)
      SmartFolder.ensure_epic_builtins!
      active = Factories.epic(user: user, repository: repo, title: "Living aqueduct", state: "ready")
      archived = Factories.epic(user: user, repository: repo, title: "Buried aqueduct", state: "archived", archived_at: Time.current)
      folder = SmartFolder.for_subject(:epic).built_in_sidebar_order.find_by!(name: "Archived")

      get root_path, params: { subject: "epic", view: "list" }

      expect(response.body).to include(active.title)
      expect(response.body).not_to include(archived.title)

      get root_path, params: { subject: "epic", view: "list", smart_folder_id: folder.id }

      expect(response.body).to include(archived.title)
      expect(response.body).not_to include(active.title)
    end

    it "saves a non-empty Epic filter as an Epic smart folder" do
      sign_in_as(user)
      filter = {
        "and" => [
          { "field" => "state", "op" => "is", "value" => "ready" },
          { "field" => "title", "op" => "contains", "value" => "Forum" }
        ]
      }

      post smart_folders_path, params: {
        subject_type: "epic",
        filter: filter.to_json,
        smart_folder: { name: "Ready forums" }
      }

      folder = user.smart_folders.find_by!(name: "Ready forums")
      expect(folder.subject_type).to eq("epic")
      expect(folder.filter).to eq(filter)
      expect(response).to redirect_to(epics_path(smart_folder_id: folder.id))

      get root_path, params: { subject: "epic", view: "list" }

      document = Nokogiri::HTML(response.body)
      saved_links = document.css("a[href='#{epics_path(smart_folder_id: folder.id)}']").map { |link| link.text.strip }
      expect(saved_links).to include(a_string_matching(/Ready forums/))
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

    it "preserves dashboard subject and view params when restoring filters" do
      result = run_filter_memory_controller(
        subject: "epic",
        search: "?subject=epic&view=list",
        stored: {
          "syrus.filter.last:job" => "q=job",
          "syrus.filter.last:epic" => "q=epic"
        }
      )

      expect(result["events"]).to eq([ [ "replace", "/epics?q=epic&subject=epic&view=list" ] ])
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
      blocker_epic = Factories.epic(user: user, repository: repo, title: "Deliver marble")
      EpicDependency.create!(epic: epic, depends_on_epic: blocker_epic, derived: false)

      get epic_path(epic)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Restore forum")
      expect(response.body).to include("Dependency graph")
      expect(response.body).to include("data-controller=\"mermaid-graph\"")
      expect(response.body).to include("(1 epic dep, 0 job blockers)")
      expect(response.body).to match(/<details[^>]*open[^>]*>.*Dependency graph/m)
    end

    it "shows the empty state when an Epic has no external dependencies" do
      sign_in_as(user)
      epic = Factories.epic(user: user, repository: repo, title: "Restore forum")
      Factories.job_record(user: user, repository: repo, epic: epic, issue_number: 20, issue_title: "Survey")

      get epic_path(epic)

      expect(response.body).to include("No external dependencies")
      expect(response.body).not_to include("data-controller=\"mermaid-graph\"")
    end

    it "links child Job titles to their Job pages" do
      sign_in_as(user)
      epic = Factories.epic(user: user, repository: repo, title: "Restore forum")
      job = Factories.job_record(user: user, repository: repo, epic: epic, issue_number: 20, issue_title: "Survey forum")

      get epic_path(epic)

      document = Nokogiri::HTML(response.body)
      title_link = document.at_css("a[href='#{job_path(job)}']")
      expect(title_link.text).to eq("Survey forum")
    end

    it "renders a drawer graph frame for Kanban cards" do
      sign_in_as(user)
      epic = Factories.epic(user: user, repository: repo, title: "Restore forum")
      blocker_epic = Factories.epic(user: user, repository: repo, title: "Deliver marble")
      EpicDependency.create!(epic: epic, depends_on_epic: blocker_epic, derived: false)

      get graph_epic_path(epic), params: { drawer: 1 }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('turbo-frame id="epic_graph_drawer_body"')
      expect(response.body).to include("Dependency graph")
      expect(response.body).to include("(1 epic dep, 0 job blockers)")
    end

    it "does not expose another user's Epic" do
      other = Factories.user
      epic = Factories.epic(user: other)
      sign_in_as(user)

      get epic_path(epic)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /epics" do
    it "creates an epic belonging to the current user and redirects to its show page" do
      sign_in_as(user)

      expect {
        post epics_path, params: {
          epic: {
            title: "Raise the forum",
            description: "Install tasteful columns.",
            repository_id: repo.id,
            github_issue_url: "https://github.com/acme/widgets/issues/12"
          }
        }
      }.to change { user.epics.count }.by(1)

      epic = user.epics.order(:id).last
      expect(epic.title).to eq("Raise the forum")
      expect(epic.description).to eq("Install tasteful columns.")
      expect(epic.repository).to eq(repo)
      expect(epic.github_issue_url).to eq("https://github.com/acme/widgets/issues/12")
      expect(response).to redirect_to(epic_path(epic))
    end

    it "re-renders new with an error when title is missing" do
      sign_in_as(user)

      expect {
        post epics_path, params: {
          epic: {
            title: "",
            repository_id: repo.id
          }
        }
      }.not_to change { user.epics.count }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("New Epic")
      expect(response.body).to include("Title can&#39;t be blank")
    end
  end

  describe "PATCH /epics/:id" do
    it "updates the epic and redirects to its show page" do
      sign_in_as(user)
      epic = Factories.epic(user: user, repository: repo, title: "Raise the forum")
      other_repo = Factories.repository(user: user, owner: "acme", name: "marble")

      patch epic_path(epic), params: {
        epic: {
          title: "Raise the basilica",
          description: "Install louder columns.",
          repository_id: other_repo.id,
          github_issue_url: "https://github.com/acme/marble/issues/7"
        }
      }

      expect(response).to redirect_to(epic_path(epic))
      expect(epic.reload).to have_attributes(
        title: "Raise the basilica",
        description: "Install louder columns.",
        repository_id: other_repo.id,
        github_issue_url: "https://github.com/acme/marble/issues/7"
      )
    end

    it "returns 404 for another user's epic" do
      other_user = Factories.user
      other_repo = Factories.repository(user: other_user)
      epic = Factories.epic(user: other_user, repository: other_repo, title: "Private aqueduct")
      sign_in_as(user)

      patch epic_path(epic), params: {
        epic: {
          title: "Rename it",
          repository_id: repo.id
        }
      }

      expect(response).to have_http_status(:not_found)
      expect(epic.reload.title).to eq("Private aqueduct")
    end
  end
end
