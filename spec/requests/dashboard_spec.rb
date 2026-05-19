require "rails_helper"
require "open3"
require "base64"
require "cgi"

RSpec.describe "Dashboard", type: :request do
  let(:user)  { Factories.user }
  let(:other) { Factories.user }

  it "requires authentication" do
    user  # force a User to exist; first-run setup redirects to new_user instead
    get dashboard_jobs_path
    expect(response).to redirect_to(new_session_path)
  end

  context "signed in" do
    before { sign_in_as(user) }

    it "renders the default Epic list dashboard at root" do
      repo = Factories.repository(user: user, owner: "acme", name: "widgets")
      Factories.epic(user: user, repository: repo, title: "Raise the forum", state: "ready")

      get root_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Epics")
      expect(response.body).to include("Raise the forum")
      expect(response.body).to include('data-filter-memory-subject-value="epic"')
    end

    it "renders root visits without params from the stored Dashboard preference" do
      repo = Factories.repository(user: user, owner: "acme", name: "widgets")
      Factories.job_record(repository: repo, issue_number: 7)
      user.update!(dashboard_preferences: { last_subject: "job", last_view: "list" })

      get root_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("acme/widgets")
      expect(response.body).to include("#7")
    end

    it "honors subject and view params at root" do
      repo = Factories.repository(user: user, owner: "acme", name: "widgets")
      Factories.job_record(repository: repo, issue_number: 7)
      Factories.epic(user: user, repository: repo, title: "Launch board", state: "ready")

      get root_path, params: { subject: "job", view: "list" }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("acme/widgets")
      expect(response.body).to include("#7")

      get root_path, params: { subject: "epic", view: "kanban" }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Backlog", "Ready", "In Progress", "Done")
      expect(response.body).to include("Launch board")
      expect(user.reload.dashboard_preferences).to eq("last_subject" => "epic", "last_view" => "kanban")
    end

    it "falls back to default dashboard params for invalid values" do
      repo = Factories.repository(user: user, owner: "acme", name: "widgets")
      Factories.epic(user: user, repository: repo, title: "Default forum", state: "ready")

      get root_path, params: { subject: "scroll", view: "mosaic" }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Epics")
      expect(response.body).to include("Default forum")
    end

    it "renders top-level navigation and points Dashboard at the default Epics subtab" do
      # The "+ New chat" link in the global nav is gated on having a
      # Claude OAuth token (per /repositories/.../chats spec). Set
      # one up so this nav-presence test exercises the chat-available
      # path; the token-missing path is covered separately.
      user.update!(claude_oauth_token: "oat-test")
      repo = Factories.repository(user: user, owner: "acme", name: "widgets")
      chat = ChatSession.create!(repository: repo, user: user, last_message_at: Time.current)

      get dashboard_jobs_path

      document = Nokogiri::HTML(response.body)
      chat_links = document.css("a[href='#{chat_path(chat)}']").map { |link| link.text.strip }
      new_chat_links = document.css("a[href='#{new_chat_path}']").map { |link| link.text.strip }
      dashboard_links = document.css("a[href='#{dashboard_epics_path}']").map { |link| link.text.strip }
      expect(chat_links).to eq([ "Syrus" ])
      expect(new_chat_links).to include("+ New chat")
      expect(dashboard_links).to include("Dashboard", "Epics")
      expect(document.at_css("a[href='#{repositories_path}']").text).to include("Repositories")
      expect(document.at_css("a[href='#{dashboard_jobs_path}']").text).to include("Jobs")
      expect(document.at_css("a[href='#{dashboard_workflows_path}']").text).to include("Workflows")
    end

    it "renders the default Dashboard preference on /dashboard inline" do
      # /dashboard used to redirect to the canonical
      # dashboard_epics/dashboard_jobs URL; it now dispatches to
      # the right view inline so the subject+view toggle in the
      # top nav can switch without round-tripping a redirect.
      get "/dashboard"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Dashboard subject")
    end

    it "updates only the explicit Dashboard preference field" do
      user.update!(dashboard_preferences: { last_subject: "epic", last_view: "kanban" })

      get "/dashboard", params: { subject: "jobs" }

      expect(response).to have_http_status(:ok)
      expect(user.reload.dashboard_preferences).to eq("last_subject" => "job", "last_view" => "kanban")
    end

    it "renders subject and view toggles on the parameterized dashboard" do
      repo = Factories.repository(user: user, owner: "acme", name: "widgets")
      Factories.job_record(repository: repo, issue_number: 7)
      Factories.epic(user: user, repository: repo, title: "Raise the forum", state: "ready")

      get root_path, params: { subject: "job", view: "list" }

      expect(response).to have_http_status(:ok)
      document = Nokogiri::HTML(response.body)
      subject_nav = document.at_css("nav[aria-label='Dashboard subject']")
      view_nav = document.at_css("nav[aria-label='Dashboard view']")

      expect(subject_nav.text.squish).to include("Epics", "Jobs", "Workflows")
      # Counts moved to the hover tooltip — visible badges were dropped
      # because three tabs + badges + chip bar + view toggle didn't fit.
      expect(subject_nav.at_css("a[href='/?subject=epic&view=list']")["title"]).to eq("1 epic matches the current filter")
      expect(subject_nav.at_css("a[href='/?subject=job&view=list']")["class"]).to include("bg-blue-600")
      expect(subject_nav.at_css("a[href='/?subject=workflow&view=list']")).to be_present
      expect(view_nav.at_css("a[href='/?subject=job&view=list']")["class"]).to include("bg-gray-800")
      expect(view_nav.at_css("a[href='/?subject=job&view=kanban']")["data-turbo-frame"]).to eq("dashboard_content")
    end

    # Regression: subject-toggle badges used to swing wildly between
    # tabs because the inactive-tab badge was computed by applying the
    # active tab's filter to the other subject's scope (cross-subject
    # filter application either rescues to total or compiles to 0,
    # depending on whether a chip name happened to exist for both
    # subjects). The fix: inactive-tab badge is always the unfiltered
    # total of that subject; active-tab badge is the filtered count.
    it "shows unfiltered totals for the inactive subject toggle, regardless of active filter" do
      repo = Factories.repository(user: user, owner: "acme", name: "widgets")
      Factories.epic(user: user, repository: repo, title: "Alpha", state: "ready")
      Factories.epic(user: user, repository: repo, title: "Beta",  state: "backlog")
      Factories.epic(user: user, repository: repo, title: "Gamma", state: "done")
      4.times { |i| Factories.job_record(repository: repo, issue_number: 100 + i) }

      # Apply a job-side filter that matches nothing (state=closed but
      # all our jobs default to queued); the Epics badge must remain
      # the total of 3, not the filter cross-applied.
      q = Filters::QueryParam.encode({ "field" => "state", "op" => "is", "value" => "closed" })
      get dashboard_jobs_path, params: { q: q }

      subject_nav = Nokogiri::HTML(response.body).at_css("nav[aria-label='Dashboard subject']")
      # Counts live in the `title` hover-tooltip now (badges removed
      # for layout reasons). The semantic check still works: the
      # inactive Epics tab tooltip reports the unfiltered total (3),
      # not the active filter cross-applied.
      expect(subject_nav.at_css("a[href*='subject=epic']")["title"]).to eq("3 epics match the current filter")
      expect(subject_nav.at_css("a[href*='subject=job']")["title"]).to eq("0 jobs match the current filter")
    end

    # Regression: the dashboard_content turbo-frame used to inherit its
    # target down to every link inside it. Clicking a job (or epic) link
    # tried to load /jobs/:id into that frame; since the show page has no
    # matching frame, Turbo rendered "Content missing". Cmd-click worked
    # because that bypasses Turbo entirely. The fix sets target="_top" on
    # the frame so out-links default to top-level navigation; the only
    # in-frame links are the view-toggle ones, which set their own
    # data-turbo-frame.
    it "marks the dashboard_content turbo-frame with target=_top so job and epic links escape it" do
      repo = Factories.repository(user: user, owner: "acme", name: "widgets")
      Factories.job_record(repository: repo, issue_number: 7)

      get dashboard_jobs_path

      document = Nokogiri::HTML(response.body)
      frame = document.at_css("turbo-frame#dashboard_content")
      expect(frame).to be_present
      expect(frame["target"]).to eq("_top")
    end

    it "renders the Epic subject with the Epic chip bar and sidebar on list view" do
      repo = Factories.repository(user: user, owner: "acme", name: "widgets")
      Factories.epic(user: user, repository: repo, title: "Raise the forum", state: "ready")

      get root_path, params: { subject: "epic", view: "list" }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-filter-memory-subject-value="epic"')
      expect(response.body).to include("&quot;field&quot;:&quot;auto_approve_mode&quot;")
      expect(response.body).to include("Raise the forum")
      expect(response.body).to include("Ready")
    end

    it "renders the Job Kanban board from the subject/view root URL" do
      repo = Factories.repository(user: user, owner: "acme", name: "widgets")
      Factories.job_record(repository: repo, issue_number: 77, issue_title: "Count the tablets")

      get root_path, params: { subject: "job", view: "kanban" }

      expect(response).to have_http_status(:ok)
      document = Nokogiri::HTML(response.body)
      expect(document.css("[data-kanban-lane] h2").map { |heading| heading.text.strip }).to eq([ "Queued", "Running", "Succeeded", "Failed" ])
      expect(response.body).to include("#77", "Count the tablets")
    end

    it "renders the Epics Kanban board with real cards" do
      repo = Factories.repository(user: user, owner: "acme", name: "widgets")
      prerequisite = Factories.epic(user: user, repository: repo, title: "Gatekeeper", state: "backlog")
      epic = Factories.epic(user: user, repository: repo, title: "Launch board", state: "ready")
      EpicDependency.create!(epic: epic, depends_on_epic: prerequisite, derived: false)
      Factories.job_record(repository: repo, epic: epic, issue_number: 7, state: "closed", closure_reason: "pr_merged")
      Factories.job_record(repository: repo, epic: epic, issue_number: 8, state: "open")

      get dashboard_epics_path

      expect(response).to have_http_status(:ok)
      document = Nokogiri::HTML(response.body)
      expect(document.at_css("[data-controller='kanban'][data-kanban-subject-value='epic']")).to be_present
      lane_titles = document.css("section h2").map { |heading| heading.text.strip }
      expect(lane_titles).to eq([ "Backlog", "Ready", "In Progress", "Done" ])

      kanban_card = document.at_css("[data-epic-id='#{epic.id}']")
      expect(kanban_card.text).to include("EPIC-#{epic.number}", "Launch board", "1/2 done", "acme/widgets", "1 dep")
      expect(kanban_card.at_css("[aria-label='Blocked']")).to be_present
      expect(kanban_card["draggable"]).to eq("true")
      expect(kanban_card["data-kanban-state-url"]).to eq(state_epic_path(epic))
      expect(kanban_card["data-epic-state-url"]).to eq(state_epic_path(epic))
      expect(response.body).to include("Override state")
    end

    it "renders the smart-folders sidebar and chip bar on the Epics Kanban view" do
      Factories.repository(user: user, owner: "acme", name: "widgets")

      get dashboard_epics_path

      document = Nokogiri::HTML(response.body)
      # The chip-bar Stimulus controller mounts with epic-specific schema data.
      chip_bar = document.at_css("[data-controller~='chip-bar'][data-filter-memory-subject-value='epic']")
      expect(chip_bar).to be_present
      expect(chip_bar["data-chip-bar-schema-value"]).to include("repository_id")
      # The built-in epic smart folders ("In progress", etc.) sit in the sidebar.
      expect(response.body).to include(">In progress<")
      # No remnants of the retired select-tag form.
      expect(response.body).not_to include("Show Done")
      expect(response.body).not_to include("Recently updated")
    end

    it "starts a ready Epic from the Kanban transition endpoint and unblocks child Jobs" do
      repo = Factories.repository(user: user, owner: "acme", name: "widgets")
      epic = Factories.epic(user: user, repository: repo, state: "ready")
      job = Factories.job_record(user: user, repository: repo, epic: epic, state: "blocked_by_epic")

      expect {
        patch state_epic_path(epic),
              params: { target_state: "in_progress" },
              headers: { "ACCEPT" => "application/json" }
      }.to change(Run, :count).by(1)

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)).to include("state" => "in_progress")
      expect(epic.reload).to be_in_progress
      expect(job.reload).to be_queued
    end

    it "unsticks an in-progress Epic from the Kanban transition endpoint and restores child Job blocks" do
      repo = Factories.repository(user: user, owner: "acme", name: "widgets")
      epic = Factories.epic(user: user, repository: repo, state: "ready")
      job = Factories.job_record(user: user, repository: repo, epic: epic, state: "blocked_by_epic")
      epic.start!

      patch state_epic_path(epic),
            params: { target_state: "ready" },
            headers: { "ACCEPT" => "application/json" }

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)).to include("state" => "ready")
      expect(epic.reload).to be_ready
      expect(job.reload).to be_blocked_by_epic
    end

    it "rejects non-ready-to-in-progress Kanban transitions server-side" do
      repo = Factories.repository(user: user, owner: "acme", name: "widgets")
      epic = Factories.epic(user: user, repository: repo, state: "backlog")

      patch state_epic_path(epic),
            params: { target_state: "done" },
            headers: { "ACCEPT" => "application/json" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)).to include("error" => "transition_not_allowed")
      expect(epic.reload).to be_backlog
    end

    it "lets the card menu override state and rolls child Jobs back when progress is reverted" do
      repo = Factories.repository(user: user, owner: "acme", name: "widgets")
      epic = Factories.epic(user: user, repository: repo, state: "ready")
      job = Factories.job_record(user: user, repository: repo, epic: epic, state: "blocked_by_epic")
      patch state_epic_path(epic), params: { target_state: "in_progress" }, headers: { "ACCEPT" => "application/json" }

      patch state_epic_path(epic), params: { target_state: "ready", override: "1" }

      expect(response).to redirect_to(dashboard_epics_path)
      expect(epic.reload).to be_ready
      expect(job.reload).to be_blocked_by_epic
      expect(job.runs.first).to be_cancelled
    end

    it "shows Done epics when requested" do
      repo = Factories.repository(user: user, owner: "acme", name: "widgets")
      done_epic = Factories.epic(user: user, repository: repo, title: "Already shipped", state: "done")

      get dashboard_epics_path, params: { done: "1" }

      expect(response.body).to include("Already shipped")
      expect(response.body).to include(epic_path(done_epic))
    end

    it "filters Epics by repository via the legacy ?repository_id= URL param" do
      repo_a = Factories.repository(user: user, owner: "acme", name: "widgets")
      repo_b = Factories.repository(user: user, owner: "acme", name: "api")
      Factories.epic(user: user, repository: repo_a, title: "Acme board", state: "backlog")
      Factories.epic(user: user, repository: repo_b, title: "Wrong repo", state: "backlog")

      get dashboard_epics_path, params: { repository_id: repo_a.id }

      expect(response.body).to include("Acme board")
      expect(response.body).not_to include("Wrong repo")
    end

    it "filters Epics by attention=blocked_by_dependency via the legacy URL param" do
      repo = Factories.repository(user: user, owner: "acme", name: "widgets")
      prerequisite = Factories.epic(user: user, repository: repo, title: "Unfinished prerequisite", state: "backlog")
      blocked = Factories.epic(user: user, repository: repo, title: "Blocked board", state: "backlog")
      Factories.epic(user: user, repository: repo, title: "Open runway", state: "backlog")
      EpicDependency.create!(epic: blocked, depends_on_epic: prerequisite, derived: false)

      get dashboard_epics_path, params: { attention: "blocked_by_dependency" }

      expect(response.body).to include("Blocked board")
      expect(response.body).not_to include("Open runway")
      expect(response.body).not_to include("Unfinished prerequisite")
    end

    it "sorts Epics within a lane by recently updated first" do
      repo = Factories.repository(user: user, owner: "acme", name: "widgets")
      older = Factories.epic(user: user, repository: repo, title: "Older board", state: "backlog")
      newer = Factories.epic(user: user, repository: repo, title: "Newer board", state: "backlog")
      older.update_columns(updated_at: 2.days.ago)
      newer.update_columns(updated_at: 1.hour.ago)

      get dashboard_epics_path

      backlog = Nokogiri::HTML(response.body).css("section").find { |section| section.at_css("h2")&.text&.strip == "Backlog" }
      card_titles = backlog.css("a").map(&:text).map(&:squish)
      expect(card_titles.first).to include("Newer board")
      expect(card_titles.second).to include("Older board")
    end

    it "renders the Epic detail page" do
      repo = Factories.repository(user: user, owner: "acme", name: "widgets")
      epic = Factories.epic(user: user, repository: repo, title: "Detail shell", state: "ready")

      get epic_path(epic)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Detail shell")
      expect(response.body).to include(epic.display_number)
      expect(response.body).to include("Back to Epics")
    end

    it "redirects legacy list URLs to root dashboard subjects" do
      get "/jobs"
      expect(response).to have_http_status(:found)
      expect(response).to redirect_to("/?subject=job")

      q = Base64.strict_encode64("status:open")
      get "/jobs", params: { q: q, smart_folder_id: "42" }
      expect(response).to have_http_status(:found)
      expect(response.location).to eq("http://www.example.com/?subject=job&q=#{CGI.escape(q)}&smart_folder_id=42")

      get "/epics"
      expect(response).to have_http_status(:found)
      expect(response).to redirect_to("/?subject=epic")

      get "/workflows"
      expect(response).to have_http_status(:found)
      expect(response).to redirect_to("/?subject=workflow")
    end

    it "lists the current user's recent jobs" do
      mine_repo = Factories.repository(user: user, owner: "acme", name: "widgets")
      Factories.job_record(repository: mine_repo, issue_number: 7)

      other_repo = Factories.repository(user: other, owner: "globex", name: "things")
      Factories.job_record(repository: other_repo, issue_number: 99)

      get dashboard_jobs_path
      expect(response.body).to include("acme/widgets")
      expect(response.body).to include("#7")
      expect(response.body).not_to include("globex/things")
      expect(response.body).not_to include("#99")
    end

    it "shows the empty state when no jobs exist" do
      get dashboard_jobs_path
      expect(response.body).to include("No jobs yet")
    end

    # Regression: HomeController#jobs used to raise NameError when an
    # epic-side filter chip lookup failed, because the rescue clause's
    # bare `Filters::UnknownFilterField` resolved through the controller's
    # ancestor chain to ActiveSupport::Callbacks::Filters instead of the
    # app-level Filters module. Triggering condition: q= encodes a field
    # the Jobs registry recognizes (`kind`) but the Epics registry does
    # not — so the matching-jobs count succeeds, the matching-epics
    # count's compiler raises UnknownFilterField, and the rescue clause
    # itself must resolve correctly.
    it "swallows epic-side UnknownFilterField when the q= chip is job-only" do
      Factories.repository(user: user, owner: "acme", name: "widgets")
      q = Filters::QueryParam.encode({ "field" => "kind", "op" => "is", "value" => "issue" })

      get dashboard_jobs_path, params: { q: q }

      expect(response).to have_http_status(:ok)
    end

    it "shows each job's workflow count instead of run count" do
      repo = Factories.repository(user: user, owner: "acme", name: "widgets")
      job = Factories.job(repository: repo, issue_number: 7)
      workflow = job.workflows.first
      workflow.first_step.runs.create!(
        job: job,
        trigger_kind: "initial",
        state: "succeeded"
      )

      get dashboard_jobs_path

      document = Nokogiri::HTML(response.body)
      row = document.at_css("tbody tr")
      expect(document.at_css("thead").text).to include("Workflows")
      expect(document.at_css("thead").text).not_to include("Runs")
      expect(row.css("td")[5].text.strip).to eq("1")
      expect(row.text).to include("1 workflow")
    end

    it "shows each job's total cost next to its state" do
      repo = Factories.repository(user: user, owner: "acme", name: "widgets")
      job = Factories.job(repository: repo, issue_number: 7)
      job.initial_run.update!(cost_usd: 1.23)

      get dashboard_jobs_path

      row = Nokogiri::HTML(response.body).at_css("tbody tr")
      expect(row.css("td")[1].text).to include("$1.23")
    end

    it "merges job state details into the issue column on mobile" do
      repo = Factories.repository(user: user, owner: "acme", name: "widgets")
      job = Factories.job(repository: repo, issue_number: 7, priority: "high")
      job.initial_run.update!(state: "failed", cost_usd: 1.23)

      get dashboard_jobs_path

      document = Nokogiri::HTML(response.body)
      state_header = document.css("thead th").find { |th| th.text.strip == "State" }
      row = document.at_css("tbody tr")
      mobile_state_summary = row.css("td")[3].css("[class]").find do |node|
        node["class"].to_s.include?("sm:hidden") && node.text.include?("failed")
      end

      expect(state_header["class"]).to include("hidden sm:table-cell")
      expect(row.css("td")[1]["class"]).to include("hidden sm:table-cell")
      expect(mobile_state_summary.text).to include("high")
      expect(mobile_state_summary.text).to include("$1.23")
    end

    it "renders a pin toggle on each job row" do
      repo = Factories.repository(user: user, owner: "acme", name: "widgets")
      job = Factories.job_record(repository: repo, issue_number: 7)

      get dashboard_jobs_path

      document = Nokogiri::HTML(response.body)
      pin = document.at_css("a[href='#{job_pin_path(job)}'][aria-label='Pin job']")
      expect(pin).to be_present
      expect(pin["data-turbo-method"]).to eq("post")
    end

    it "renders the read-only Job Kanban board bucketed by latest workflow state" do
      repo = Factories.repository(user: user, owner: "acme", name: "widgets")
      pre_run = Factories.job_record(repository: repo, issue_number: 1, issue_title: "Await the first trumpet")
      running = Factories.job(repository: repo, issue_number: 2, issue_title: "March immediately")
      running.latest_workflow.update!(state: "running", created_at: 3.minutes.ago)
      succeeded = Factories.job(repository: repo, issue_number: 3, issue_title: "Return triumphant", pr_number: 8)
      succeeded.latest_workflow.update!(state: "succeeded", created_at: 2.minutes.ago)
      succeeded.initial_run.update!(state: "succeeded")
      failed = Factories.job(repository: repo, issue_number: 4, issue_title: "Drop the standard")
      failed.latest_workflow.update!(state: "failed", trigger_kind: "retry", created_at: 1.minute.ago)
      failed.initial_run.update!(state: "failed")

      get dashboard_jobs_path, params: { view: "kanban" }

      expect(response).to have_http_status(:ok)
      document = Nokogiri::HTML(response.body)
      lane_titles = document.css("[data-kanban-lane] h2").map { |heading| heading.text.strip }
      expect(lane_titles).to eq([ "Queued", "Running", "Succeeded", "Failed" ])

      expect(document.at_css("[data-kanban-lane='queued']").text).to include("#1", "Await the first trumpet", "No workflow yet")
      expect(document.at_css("[data-kanban-lane='running']").text).to include("#2", "March immediately", "running", "initial")
      expect(document.at_css("[data-kanban-lane='succeeded']").text).to include("#3", "Return triumphant", "awaiting feedback")
      expect(document.at_css("[data-kanban-lane='failed']").text).to include("#4", "Drop the standard", "failed", "retry")

      card = document.at_css("[data-job-id='#{failed.id}']")
      expect(card.name).to eq("a")
      expect(card["href"]).to eq(job_path(failed))
      expect(card["draggable"]).to be_nil
    end

    it "keeps filters applied in the Job Kanban view" do
      repo_a = Factories.repository(user: user, owner: "acme", name: "alpha")
      repo_b = Factories.repository(user: user, owner: "acme", name: "beta")
      Factories.job_record(repository: repo_a, issue_number: 10, issue_title: "Correct province")
      Factories.job_record(repository: repo_b, issue_number: 20, issue_title: "Wrong province")

      get dashboard_jobs_path, params: { view: "kanban", repository_id: repo_a.id }

      expect(response.body).to include("#10", "Correct province")
      expect(response.body).not_to include("#20")
      expect(response.body).not_to include("Wrong province")
    end

    it "caps the Job Kanban board at the first 100 filtered jobs" do
      repo = Factories.repository(user: user, owner: "acme", name: "widgets")
      101.times do |index|
        Factories.job_record(repository: repo, issue_number: index + 1, issue_title: "Inscription #{index + 1}")
      end

      get dashboard_jobs_path, params: { view: "kanban" }

      document = Nokogiri::HTML(response.body)
      expect(document.css("[data-job-id]").size).to eq(100)
      expect(response.body).to include("Showing the first 100 jobs; refine filters to narrow the board.")
    end

    it "shows pinned jobs for the current user sorted by pinned time via the pinned smart folder" do
      repo = Factories.repository(user: user, owner: "acme", name: "widgets")
      older = Factories.job_record(repository: repo, issue_number: 1)
      newer = Factories.job_record(repository: repo, issue_number: 2)
      unpinned = Factories.job_record(repository: repo, issue_number: 3)
      other_repo = Factories.repository(user: other, owner: "globex", name: "things")
      others_pin = Factories.job_record(repository: other_repo, issue_number: 4)

      Factories.job_pin(user: user, job: older).update!(created_at: 2.hours.ago)
      Factories.job_pin(user: user, job: newer).update!(created_at: 1.hour.ago)
      Factories.job_pin(user: other, job: others_pin)

      SmartFolder.ensure_builtins!
      pinned_folder = SmartFolder.find_builtin_by_attention("pinned")
      get dashboard_jobs_path, params: { smart_folder_id: pinned_folder.id }

      document = Nokogiri::HTML(response.body)
      rows = document.css("tbody tr").map(&:text)
      expect(rows.size).to eq(2)
      expect(rows[0]).to include("#2")
      expect(rows[1]).to include("#1")
      expect(response.body).not_to include("#3")
      expect(response.body).not_to include("#4")
      expect(response.body).to include("Pinned")
      expect(document.at_css("a[href='#{job_pin_path(newer)}'][aria-label='Unpin job']")["data-turbo-method"]).to eq("delete")
    end

    it "exposes every built-in smart folder's attention preset in the chip-bar schema" do
      # Replaces the legacy <select name="attention"> dropdown spec —
      # the chip-bar now drives attention selection. The dashboard
      # serializes the schema (including every Attention preset) into
      # data-chip-bar-schema-value on the controller root.
      Factories.repository(user: user, owner: "acme", name: "widgets")

      get dashboard_jobs_path

      schema_attr = Nokogiri::HTML(response.body).at_css("[data-chip-bar-schema-value]")&.[]("data-chip-bar-schema-value")
      expect(schema_attr).to be_present
      schema = JSON.parse(schema_attr)
      attention_chip = schema.find { |c| c["field"] == "attention" }
      expect(attention_chip).to be_present
      preset_values = attention_chip["values"].map { |v| v["value"] }
      expected = SmartFolder::BUILTIN_DEFINITIONS.filter_map do |definition|
        chip = Array(definition[:filter]["and"]).find { |c| c["field"] == "attention" }
        chip&.dig("value")
      end
      expect(preset_values).to include(*expected)
    end

    it "collapses folders and filters by default on mobile only" do
      repo = Factories.repository(user: user, owner: "acme", name: "widgets")
      user.smart_folders.create!(
        name: "Open PRs",
        kind: "user_defined",
        position: 0,
        filter: { "and" => [ { "field" => "pr_present", "op" => "is", "value" => "has" } ] }
      )
      Factories.job_record(repository: repo, issue_number: 1)

      get dashboard_jobs_path

      document = Nokogiri::HTML(response.body)
      mobile_panel = document.at_css("details")
      desktop_sidebar = document.at_css("aside")
      # The legacy <select name="attention"> dropdown form is gone —
      # the chip-bar is the filter UI. The desktop chip-bar now lives
      # in the top controls row (between subject + view toggles),
      # inside a wrapper marked `hidden lg:block`.
      desktop_chip_bar = document.css("[data-controller~='chip-bar']").find do |el|
        parent_class = el.parent&.[]("class").to_s
        parent_class.include?("lg:block") && parent_class.include?("hidden")
      end

      expect(mobile_panel).to be_present
      expect(mobile_panel["class"]).to include("lg:hidden")
      expect(mobile_panel["open"]).to be_nil
      expect(mobile_panel.at_css("summary").text).to include("Folders and filters")
      expect(mobile_panel.text).to include("Attention")
      expect(mobile_panel.text).to include("Open PRs")
      expect(mobile_panel.at_css("[data-controller~='chip-bar']")).to be_present

      expect(desktop_sidebar["class"]).to include("hidden")
      expect(desktop_sidebar["class"]).to include("lg:block")
      expect(desktop_chip_bar).to be_present
    end

    it "excludes closed jobs from the inbox even when they have a failed latest run" do
      repo = Factories.repository(user: user, owner: "acme", name: "widgets")
      open_failed = Factories.job(repository: repo, issue_number: 1)
      open_failed.initial_run.update!(state: "failed", finished_at: Time.current)
      closed_failed = Factories.job(repository: repo, issue_number: 2)
      closed_failed.initial_run.update!(state: "failed", finished_at: Time.current)
      closed_failed.close!; closed_failed.save!

      get dashboard_jobs_path, params: { attention: "inbox" }

      expect(response.body).to include("#1")
      expect(response.body).not_to include("#2")
    end

    it "filters jobs by attention=just_failed when picked from the dropdown" do
      repo = Factories.repository(user: user, owner: "acme", name: "widgets")
      failing = Factories.job(repository: repo, issue_number: 1)
      failing.initial_run.update!(state: "failed", finished_at: Time.current)
      Factories.job(repository: repo, issue_number: 2)

      get dashboard_jobs_path, params: { attention: "just_failed" }

      expect(response.body).to include("#1")
      expect(response.body).not_to include("#2")
    end

    it "shows the pinned folder's count scoped to the user's pins, not all jobs" do
      repo = Factories.repository(user: user, owner: "acme", name: "widgets")
      pinned = Factories.job_record(repository: repo, issue_number: 1)
      4.times { |i| Factories.job_record(repository: repo, issue_number: 100 + i) }
      Factories.job_pin(user: user, job: pinned)

      SmartFolder.ensure_builtins!
      pinned_folder = SmartFolder.find_builtin_by_attention("pinned")
      get dashboard_jobs_path

      sidebar = Nokogiri::HTML(response.body).at_css("aside")
      pinned_row = sidebar.css("a").find { |a| a["href"] == dashboard_jobs_path(smart_folder_id: pinned_folder.id) }
      expect(pinned_row).to be_present
      expect(pinned_row.text).to match(/Pinned\s+1\b/)
    end

    it "hides the Pinned sidebar entry when the user has nothing pinned" do
      Factories.repository(user: user, owner: "acme", name: "widgets")

      get dashboard_jobs_path

      sidebar = Nokogiri::HTML(response.body).at_css("aside")
      expect(sidebar.text).not_to include("Pinned")
    end

    it "keeps the Pinned sidebar entry visible when it is the active folder, even if empty" do
      Factories.repository(user: user, owner: "acme", name: "widgets")
      SmartFolder.ensure_builtins!
      pinned_folder = SmartFolder.find_builtin_by_attention("pinned")

      get dashboard_jobs_path, params: { smart_folder_id: pinned_folder.id }

      sidebar = Nokogiri::HTML(response.body).at_css("aside")
      expect(sidebar.text).to include("Pinned")
    end

    it "shows the In progress folder when a job has a queued or running workflow" do
      repo = Factories.repository(user: user, owner: "acme", name: "widgets")
      running = Factories.job(repository: repo, issue_number: 1)
      running.workflows.first.update!(state: "running", started_at: Time.current)
      idle = Factories.job(repository: repo, issue_number: 2)
      idle.workflows.first.update!(state: "succeeded", started_at: 1.hour.ago, finished_at: Time.current)
      closed = Factories.job(repository: repo, issue_number: 3) # initial workflow defaults to queued
      closed.close!
      closed.save!

      get dashboard_jobs_path

      sidebar = Nokogiri::HTML(response.body).at_css("aside")
      in_progress_row = sidebar.css("a").find { |a| a.text.include?("In progress") }
      expect(in_progress_row).to be_present
      expect(in_progress_row.text).to match(/In progress\s+1\b/)
    end

    it "hides the In progress folder when nothing is queued or running" do
      repo = Factories.repository(user: user, owner: "acme", name: "widgets")
      done = Factories.job(repository: repo, issue_number: 1)
      done.workflows.first.update!(state: "succeeded", started_at: 1.hour.ago, finished_at: Time.current)

      get dashboard_jobs_path

      sidebar = Nokogiri::HTML(response.body).at_css("aside")
      expect(sidebar.text).not_to include("In progress")
    end

    it "filters jobs by attention=in_progress" do
      repo = Factories.repository(user: user, owner: "acme", name: "widgets")
      running = Factories.job(repository: repo, issue_number: 1)
      running.workflows.first.update!(state: "running", started_at: Time.current)
      queued = Factories.job(repository: repo, issue_number: 2) # initial workflow defaults to queued
      done = Factories.job(repository: repo, issue_number: 3)
      done.workflows.first.update!(state: "succeeded", started_at: 1.hour.ago, finished_at: Time.current)
      closed = Factories.job(repository: repo, issue_number: 4) # initial workflow defaults to queued
      closed.close!
      closed.save!

      get dashboard_jobs_path, params: { attention: "in_progress" }

      expect(response.body).to include("#1")
      expect(response.body).to include("#2")
      expect(response.body).not_to include("#3")
      expect(response.body).not_to include("#4")
    end

    it "keeps normal filters available in the pinned smart folder view" do
      repo = Factories.repository(user: user, owner: "acme", name: "widgets")
      open_job = Factories.job_record(repository: repo, issue_number: 1)
      closed_job = Factories.job_record(repository: repo, issue_number: 2)
      closed_job.close!; closed_job.save!
      Factories.job_pin(user: user, job: open_job)
      Factories.job_pin(user: user, job: closed_job)

      SmartFolder.ensure_builtins!
      pinned_folder = SmartFolder.find_builtin_by_attention("pinned")
      get dashboard_jobs_path, params: { smart_folder_id: pinned_folder.id, state: "closed" }

      expect(response.body).not_to include("#1")
      expect(response.body).to include("#2")
    end

    it "does not carry smart_folder_id through the chip-bar form so manual changes break out of the folder" do
      # Legacy dropdown form is gone; the chip-bar's hidden form
      # carries only the encoded `q` AST tree. Smart folder identity
      # is not round-tripped through the form — the operator is
      # supposed to break out of the folder by editing the chips,
      # not by toggling form state.
      Factories.repository(user: user, owner: "acme", name: "widgets")
      SmartFolder.ensure_builtins!
      inbox = SmartFolder.find_builtin_by_attention("inbox")

      get dashboard_jobs_path, params: { smart_folder_id: inbox.id }

      document = Nokogiri::HTML(response.body)
      chip_bar_form = document.at_css("[data-controller~='chip-bar'] form")
      expect(chip_bar_form).to be_present
      expect(chip_bar_form.at_css("input[name='smart_folder_id']")).to be_nil
      # The form's hidden q input is the only data it submits.
      hidden_inputs = chip_bar_form.css("input[type='hidden']").map { |i| i["name"] }
      expect(hidden_inputs).to include("q")
    end

    it "exposes a Clear control on the chip-bar so the operator can drop all filters" do
      # The Clear UX is now a chip-bar Stimulus button (not an anchor).
      # When the filter is active, it appears and triggers
      # chip-bar#clearAll which submits the form with an empty tree.
      Factories.repository(user: user, owner: "acme", name: "widgets")
      SmartFolder.ensure_builtins!
      inbox = SmartFolder.find_builtin_by_attention("inbox")

      get dashboard_jobs_path, params: { smart_folder_id: inbox.id, state: "open" }

      clear_button = Nokogiri::HTML(response.body).css("button").find { |b| b.text.strip == "Clear" }
      expect(clear_button).to be_present
      expect(clear_button["data-action"]).to include("chip-bar#clearAll")
    end

    it "shows up to three tag chips with overflow in job rows" do
      repo = Factories.repository(user: user, owner: "acme", name: "widgets")
      job = Factories.job_record(repository: repo, issue_number: 7)
      %w[alpha beta gamma zeta].each { |name| job.tags << Factories.tag(user: user, name: name) }

      get dashboard_jobs_path

      row_text = Nokogiri::HTML(response.body).at_css("tbody tr").text
      expect(row_text).to include("alpha")
      expect(row_text).to include("beta")
      expect(row_text).to include("gamma")
      expect(row_text).to include("+1 more")
      expect(row_text).not_to include("zeta")
    end

    it "shows the latest workflow type and status in a desktop-only column" do
      repo = Factories.repository(user: user, owner: "acme", name: "widgets")
      job = Factories.job(repository: repo, issue_number: 7)
      Workflow.create!(
        job: job,
        trigger_kind: "pr_comment",
        state: "failed",
        created_at: 1.minute.from_now
      )

      get dashboard_jobs_path

      document = Nokogiri::HTML(response.body)
      status_cell = document.css("tbody tr td")[1]
      issue_cell = document.css("tbody tr td")[3]
      latest_cell = document.css("tbody tr td")[4]

      expect(document.at_css("thead").text).to include("Latest")
      expect(status_cell["class"]).to include("hidden sm:table-cell")
      expect(status_cell.text).not_to include("failed")
      expect(status_cell.text).not_to include("pr_comment")
      expect(issue_cell.text).not_to include("pr_comment")
      expect(latest_cell["class"]).to include("hidden sm:table-cell")
      expect(latest_cell.text).to include("failed")
      expect(latest_cell.text).to include("pr_comment")
    end

    it "shows the latest workflow for closed jobs without mixing it into job status" do
      repo = Factories.repository(user: user, owner: "acme", name: "widgets")
      job = Factories.job(repository: repo, issue_number: 7)
      job.close!
      job.save!

      get dashboard_jobs_path

      document = Nokogiri::HTML(response.body)
      status_cell = document.css("tbody tr td")[1]
      latest_cell = document.css("tbody tr td")[4]

      expect(status_cell.text).to include("closed")
      expect(status_cell.text).not_to include("initial")
      expect(latest_cell.text).to include("initial")
      expect(latest_cell.text).to include("queued")
    end

    describe "bulk job actions" do
      let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets", auto_merge_enabled: true) }

      def finish_initial_work(job, provider: "claude")
        job.initial_run.update!(
          state: "succeeded",
          started_at: 2.minutes.ago,
          finished_at: 1.minute.ago,
          agent_provider: provider
        )
        job.latest_workflow.update!(state: "succeeded", started_at: 2.minutes.ago, finished_at: 1.minute.ago)
      end

      it "renders row checkboxes, a select-all checkbox, and hidden bulk actions" do
        job = Factories.job(repository: repo, issue_number: 7)
        Factories.tag(user: user, name: "epic:attachments", color: "blue")

        get dashboard_jobs_path

        document = Nokogiri::HTML(response.body)
        expect(document.at_css("form[action='#{bulk_dashboard_jobs_path}'][data-controller='bulk-jobs']")).to be_present
        expect(document.at_css("input[aria-label='Select all jobs'][data-bulk-jobs-target='selectAll']")).to be_present
        expect(document.at_css("input[name='job_ids[]'][value='#{job.id}'][data-bulk-jobs-target='checkbox']")).to be_present
        expect(document.at_css("[data-bulk-jobs-target='actions']")["class"]).to include("hidden")
        expect(response.body).to include("Bulk actions")
        expect(response.body).to include("Retry")
        expect(response.body).to include("Close")
        expect(response.body).to include("Approve")
        expect(response.body).to include("Review and approve")
        expect(response.body).to include("Apply tag")
        expect(response.body).to include("epic:attachments")
      end

      it "renders all configured agent retry choices when more than one agent is configured" do
        user.update!(claude_oauth_token: "oat-test", codex_auth_mode: "api_key", codex_api_key: "sk-test")
        Factories.job(repository: repo, issue_number: 7)

        get dashboard_jobs_path

        expect(response.body).to include("Retry with Claude")
        expect(response.body).to include("Retry with Codex")
      end

      it "does not render agent-specific retry choices with only one configured agent" do
        user.update!(claude_oauth_token: "oat-test", codex_api_key: nil)
        Factories.job(repository: repo, issue_number: 7)

        get dashboard_jobs_path

        expect(response.body).not_to include("Retry with Claude")
        expect(response.body).not_to include("Retry with Codex")
      end

      it "bulk retries selected open idle jobs using each job's current agent by default" do
        first = Factories.job(repository: repo, issue_number: 1, agent_provider: "claude")
        second = Factories.job(repository: repo, issue_number: 2, agent_provider: "codex")
        finish_initial_work(first, provider: "claude")
        finish_initial_work(second, provider: "codex")

        expect {
          post bulk_dashboard_jobs_path, params: { job_ids: [ first.id, second.id ], bulk_action: "retry" }
        }.to change { Workflow.where(trigger_kind: "retry").count }.by(2)

        expect(first.reload.latest_workflow.agent_provider).to eq("claude")
        expect(second.reload.latest_workflow.agent_provider).to eq("codex")
        expect(flash[:notice]).to match(/Retry enqueued for 2 jobs/)
      end

      it "bulk retries with a selected configured agent and updates the jobs" do
        user.update!(claude_oauth_token: "oat-test", codex_auth_mode: "api_key", codex_api_key: "sk-test")
        first = Factories.job(repository: repo, issue_number: 1, agent_provider: "claude")
        second = Factories.job(repository: repo, issue_number: 2, agent_provider: "claude")
        finish_initial_work(first)
        finish_initial_work(second)

        post bulk_dashboard_jobs_path, params: { job_ids: [ first.id, second.id ], bulk_action: "retry:codex" }

        expect(first.reload.agent_provider).to eq("codex")
        expect(second.reload.agent_provider).to eq("codex")
        expect(first.latest_workflow.agent_provider).to eq("codex")
        expect(second.latest_workflow.agent_provider).to eq("codex")
        expect(flash[:notice]).to match(/with Codex/)
      end

      it "does not retry closed or active selected jobs" do
        idle = Factories.job(repository: repo, issue_number: 1)
        closed = Factories.job(repository: repo, issue_number: 2)
        active = Factories.job(repository: repo, issue_number: 3)
        finish_initial_work(idle)
        closed.close_with_reason!("manual")

        expect {
          post bulk_dashboard_jobs_path, params: { job_ids: [ idle.id, closed.id, active.id ], bulk_action: "retry" }
        }.to change { idle.reload.workflows.where(trigger_kind: "retry").count }.by(1)
          .and change { closed.reload.workflows.where(trigger_kind: "retry").count }.by(0)
          .and change { active.reload.workflows.where(trigger_kind: "retry").count }.by(0)
      end

      it "bulk closes selected open jobs and cancels active runs" do
        open_job = Factories.job(repository: repo, issue_number: 1)
        active_job = Factories.job(repository: repo, issue_number: 2)

        post bulk_dashboard_jobs_path, params: { job_ids: [ open_job.id, active_job.id ], bulk_action: "close" }

        expect(open_job.reload).to be_closed
        expect(active_job.reload).to be_closed
        expect(active_job.initial_run.reload).to be_cancelled
        expect(flash[:notice]).to match(/2 jobs closed/)
      end

      # Regression: bulk-approving Jobs whose repo has auto_merge
      # disabled used to silently succeed, then get wiped on the next
      # landing tick. Skip those Jobs with a clear flash that names
      # the affected repos so the operator can enable auto-merge.
      it "bulk approve skips Jobs whose repository has auto-merge disabled" do
        no_automerge_repo = Factories.repository(user: user, owner: "acme", name: "lib", auto_merge_enabled: false)
        enabled = Factories.job(repository: repo, issue_number: 10)
        disabled = Factories.job(repository: no_automerge_repo, issue_number: 11)
        enabled.update!(state: "implemented")
        disabled.update!(state: "implemented")

        post bulk_dashboard_jobs_path, params: { job_ids: [ enabled.id, disabled.id ], bulk_action: "approve" }

        expect(enabled.reload.state).to eq("approved")
        expect(disabled.reload.state).to eq("implemented")
        expect(disabled.approved_at).to be_nil
        expect(flash[:notice]).to include("Approved 1 job in batch")
        expect(flash[:notice]).to include("Skipped 1 job whose repository has auto-merge disabled (acme/lib)")
      end

      it "bulk approves selected implemented jobs with a shared batch id" do
        first = Factories.job(repository: repo, issue_number: 1)
        second = Factories.job(repository: repo, issue_number: 2)
        first.update!(state: "implemented")
        second.update!(state: "implemented")

        post bulk_dashboard_jobs_path, params: { job_ids: [ first.id, second.id ], bulk_action: "approve" }

        expect(first.reload.state).to eq("approved")
        expect(second.reload.state).to eq("approved")
        expect(first.approved_via).to eq("bulk")
        expect(second.approved_via).to eq("bulk")
        expect(first.approved_by_user).to eq(user)
        expect(second.approved_by_user).to eq(user)
        expect(first.approval_evidence.fetch("batch_id")).to be_present
        expect(second.approval_evidence.fetch("batch_id")).to eq(first.approval_evidence.fetch("batch_id"))
      end

      it "bulk approve files APPROVE reviews for opted-in repositories" do
        first = Factories.job(repository: repo, issue_number: 1)
        second = Factories.job(repository: repo, issue_number: 2)
        first.update!(state: "implemented", pr_number: 101)
        second.update!(state: "implemented", pr_number: 102)
        client = instance_double(GithubClient)
        allow(GithubClient).to receive(:for).with(repository: repo, user: user).and_return(client)
        expect(client).to receive(:create_pr_review)
          .with(repo.slug, 101, event: "APPROVE", body: a_string_including("Syrus"))
          .and_return(Struct.new(:id).new(901))
        expect(client).to receive(:create_pr_review)
          .with(repo.slug, 102, event: "APPROVE", body: a_string_including("Syrus"))
          .and_return(Struct.new(:id).new(902))

        post bulk_dashboard_jobs_path, params: { job_ids: [ first.id, second.id ], bulk_action: "approve" }

        expect(first.reload.approval_evidence).to include("batch_id", "github_review_id" => 901)
        expect(second.reload.approval_evidence).to include("batch_id", "github_review_id" => 902)
        expect(flash[:notice]).to include("GitHub reviews left for 2 jobs")
      end

      it "bulk approve skips GitHub reviews for opted-out repositories" do
        repo.update!(approval_propagates_to_github: false)
        job = Factories.job(repository: repo, issue_number: 1)
        job.update!(state: "implemented", pr_number: 101)
        expect(GithubClient).not_to receive(:for)

        post bulk_dashboard_jobs_path, params: { job_ids: [ job.id ], bulk_action: "approve" }

        expect(job.reload.state).to eq("approved")
        expect(job.approval_evidence).not_to have_key("github_review_id")
        expect(flash[:notice]).to match(/\AApproved 1 job in batch/)
      end

      it "bulk approve keeps Syrus approvals and flashes when GitHub review propagation fails" do
        job = Factories.job(repository: repo, issue_number: 1)
        job.update!(state: "implemented", pr_number: 101)
        client = instance_double(GithubClient)
        allow(GithubClient).to receive(:for).with(repository: repo, user: user).and_return(client)
        allow(client).to receive(:create_pr_review)
          .and_raise(Octokit::UnprocessableEntity.new(body: { message: "Pull request author can't approve their own pull request" }))

        post bulk_dashboard_jobs_path, params: { job_ids: [ job.id ], bulk_action: "approve" }

        expect(job.reload.state).to eq("approved")
        expect(job.approval_evidence).not_to have_key("github_review_id")
        expect(flash[:notice]).to include("GitHub review failed")
      end

      it "renders a sequential review drawer for selected implemented jobs" do
        first = Factories.job(repository: repo, issue_number: 1, issue_title: "Review the aqueduct")
        second = Factories.job(repository: repo, issue_number: 2, issue_title: "Review the forum")
        first.update!(state: "implemented")
        second.update!(state: "implemented")
        first.initial_run.update!(agent_diff: "diff --git a/a.txt b/a.txt\n+first")
        second.initial_run.update!(agent_diff: "diff --git a/b.txt b/b.txt\n+second")

        post bulk_dashboard_jobs_path, params: { job_ids: [ first.id, second.id ], bulk_action: "review_approve" }

        expect(response).to be_successful
        expect(response.body).to include("Review and approve")
        expect(response.body).to include("Review the aqueduct")
        expect(response.body).to include("Review the forum")
        expect(response.body).to include("+first")
        expect(response.body).to include("+second")
        expect(response.body).to include("Commit approved batch")
        expect(response.body).to include(%(name="approval_choices[#{first.id}]"))
        expect(response.body).to include(%(name="approval_choices[#{second.id}]"))
      end

      it "commits reviewed approvals and skips rejected jobs" do
        approved = Factories.job(repository: repo, issue_number: 1)
        skipped = Factories.job(repository: repo, issue_number: 2)
        approved.update!(state: "implemented")
        skipped.update!(state: "implemented")

        post bulk_dashboard_jobs_path, params: {
          job_ids: [ approved.id, skipped.id ],
          bulk_action: "commit_review_approval",
          approval_choices: {
            approved.id.to_s => "approve",
            skipped.id.to_s => "skip"
          }
        }

        expect(approved.reload.state).to eq("approved")
        expect(skipped.reload.state).to eq("implemented")
        expect(approved.approved_via).to eq("bulk")
        expect(approved.approval_evidence.fetch("batch_id")).to be_present
      end

      it "does not bulk mutate another user's jobs" do
        mine = Factories.job(repository: repo, issue_number: 1)
        their_repo = Factories.repository(user: other, owner: "globex", name: "things")
        theirs = Factories.job(repository: their_repo, issue_number: 2)

        post bulk_dashboard_jobs_path, params: { job_ids: [ mine.id, theirs.id ], bulk_action: "close" }

        expect(mine.reload).to be_closed
        expect(theirs.reload).to be_open
      end

      it "bulk applies an existing tag to selected jobs" do
        first = Factories.job(repository: repo, issue_number: 1)
        second = Factories.job(repository: repo, issue_number: 2)
        tag = Factories.tag(user: user, name: "epic:tags", color: "indigo")

        post bulk_dashboard_jobs_path, params: { job_ids: [ first.id, second.id ], bulk_action: "apply_tag", tag_id: tag.id }

        expect(first.reload.tags).to contain_exactly(tag)
        expect(second.reload.tags).to contain_exactly(tag)
        expect(flash[:notice]).to include("Applied epic:tags to 2 jobs")
      end

      it "bulk creates a new tag inline" do
        first = Factories.job(repository: repo, issue_number: 1)

        expect {
          post bulk_dashboard_jobs_path, params: { job_ids: [ first.id ], bulk_action: "apply_tag", tag_name: "theme:cleanup" }
        }.to change { user.tags.count }.by(1)

        expect(first.reload.tags.pluck(:name)).to eq([ "theme:cleanup" ])
      end
    end

    describe "Workflows tab" do
      it "renders the empty state when no workflows exist" do
        get dashboard_workflows_path
        expect(response.body).to include("No workflows yet")
      end

      it "lists workflows for the current user with dashboard fields" do
        repo = Factories.repository(user: user, owner: "acme", name: "widgets")
        job = Factories.job(repository: repo, issue_number: 7, issue_title: "Raise the aqueduct")
        workflow = job.latest_workflow
        workflow.update!(state: "running", started_at: 10.minutes.ago, agent_provider: "codex")

        get root_path, params: { subject: "workflow", view: "list" }

        document = Nokogiri::HTML(response.body)
        expect(response.body).to include("acme/widgets")
        expect(response.body).to include("Raise the aqueduct")
        expect(document.at_css("a[href='#{job_path(job, anchor: "workflow_#{workflow.id}")}']").text).to include("##{workflow.id}")
        expect(document.at_css("a[href='#{job_path(job)}']").text).to include("##{job.id}")
        expect(response.body).to include("initial", "running", "Codex")
      end

      it "merges workflow state into the issue column on mobile" do
        repo = Factories.repository(user: user, owner: "acme", name: "widgets")
        job = Factories.job(repository: repo, issue_number: 7)
        job.latest_workflow.update!(state: "running")

        get dashboard_workflows_path

        document = Nokogiri::HTML(response.body)
        state_header = document.css("thead th").find { |th| th.text.strip == "State" }
        row = document.at_css("tbody tr")
        mobile_state_summary = row.css("td")[0].css("[class]").find do |node|
          node["class"].to_s.include?("sm:hidden") && node.text.include?("running")
        end

        expect(state_header["class"]).to include("hidden sm:table-cell")
        expect(mobile_state_summary.text).to include("initial")
      end

      it "scopes to the current user (no leakage)" do
        mine = Factories.repository(user: user, owner: "acme", name: "widgets")
        Factories.job(repository: mine, issue_number: 7)
        theirs = Factories.repository(user: other, owner: "globex", name: "things")
        Factories.job(repository: theirs, issue_number: 99)
        get dashboard_workflows_path
        expect(response.body).to include("acme/widgets")
        expect(response.body).not_to include("globex/things")
      end

      it "shows the default non-terminal or recent workflow filter as the chip-bar tree" do
        repo = Factories.repository(user: user, owner: "acme", name: "widgets")
        recent_job = Factories.job(repository: repo, issue_number: 1, issue_title: "Recent failure")
        recent_job.latest_workflow.update!(state: "failed", finished_at: 2.days.ago)
        old_job = Factories.job(repository: repo, issue_number: 2, issue_title: "Ancient failure")
        old_job.latest_workflow.update!(state: "failed", finished_at: 8.days.ago)

        get root_path, params: { subject: "workflow", view: "list" }

        document = Nokogiri::HTML(response.body)
        tree = JSON.parse(document.at_css("[data-chip-bar-tree-value]")["data-chip-bar-tree-value"])
        expect(tree).to eq(Workflows::Filter.default_tree)
        # Check the table body specifically, not the whole page — Job
        # titles now also appear in the chip-bar's job_id picker
        # schema JSON, so a broad response.body assertion would match
        # the picker options as well as rendered rows.
        tbody_text = document.at_css("tbody").text
        expect(tbody_text).to include("Recent failure")
        expect(tbody_text).not_to include("Ancient failure")
      end

      it "preserves an explicit empty workflow q param instead of re-applying the default" do
        repo = Factories.repository(user: user, owner: "acme", name: "widgets")
        old_job = Factories.job(repository: repo, issue_number: 1, issue_title: "Ancient failure")
        old_job.latest_workflow.update!(state: "failed", finished_at: 8.days.ago)
        q = Filters::QueryParam.encode("and" => [])

        get root_path, params: { subject: "workflow", view: "list", q: q }

        document = Nokogiri::HTML(response.body)
        tree = JSON.parse(document.at_css("[data-chip-bar-tree-value]")["data-chip-bar-tree-value"])
        expect(tree).to eq("and" => [])
        expect(document.at_css("tbody").text).to include("Ancient failure")
        expect(document.css("button").map(&:text).map(&:strip)).not_to include("Clear")
      end

      it "lets an explicit workflow chip filter narrow the list" do
        repo = Factories.repository(user: user, owner: "acme", name: "widgets")
        running = Factories.job(repository: repo, issue_number: 1, issue_title: "Still marching")
        running.latest_workflow.update!(state: "running", started_at: 5.minutes.ago)
        queued = Factories.job(repository: repo, issue_number: 2, issue_title: "Awaiting orders")
        queued.latest_workflow.update!(state: "queued")
        q = Filters::QueryParam.encode("and" => [ { "field" => "state", "op" => "is", "value" => "running" } ])

        get root_path, params: { subject: "workflow", view: "list", q: q }

        tbody_text = Nokogiri::HTML(response.body).at_css("tbody").text
        expect(tbody_text).to include("Still marching")
        expect(tbody_text).not_to include("Awaiting orders")
      end

      it "renders the Workflow kanban as queued, running, and done columns without drag handles" do
        repo = Factories.repository(user: user, owner: "acme", name: "widgets")
        queued = Factories.job(repository: repo, issue_number: 1, issue_title: "Await the trumpet")
        queued.latest_workflow.update!(state: "queued")
        running = Factories.job(repository: repo, issue_number: 2, issue_title: "Cross the Rubicon")
        running.latest_workflow.update!(state: "running", started_at: 4.minutes.ago)
        failed = Factories.job(repository: repo, issue_number: 3, issue_title: "Misplace the laurel")
        failed.latest_workflow.update!(state: "failed", finished_at: 12.minutes.ago)

        get root_path, params: { subject: "workflow", view: "kanban" }

        document = Nokogiri::HTML(response.body)
        expect(document.css("[data-kanban-lane] h2").map { |heading| heading.text.strip }).to eq([ "Queued", "Running", "Done" ])
        expect(document.at_css("[data-controller='kanban']")).to be_nil
        expect(document.at_css("[data-kanban-lane='queued']").text).to include("Await the trumpet")
        expect(document.at_css("[data-kanban-lane='running']").text).to include("Cross the Rubicon", "running for")
        expect(document.at_css("[data-kanban-lane='done']").text).to include("Misplace the laurel", "failed")
        expect(document.css("[data-workflow-id]").map { |card| card["draggable"] }).to all(be_nil)
      end

      it "caps workflow kanban at the shared kanban page size" do
        repo = Factories.repository(user: user, owner: "acme", name: "widgets")
        (HomeController::KANBAN_PER_PAGE + 1).times do |idx|
          job = Factories.job(repository: repo, issue_number: idx + 1, issue_title: "Workflow #{idx + 1}")
          job.latest_workflow.update!(state: "queued")
        end

        get root_path, params: { subject: "workflow", view: "kanban" }

        document = Nokogiri::HTML(response.body)
        expect(document.css("[data-workflow-id]").size).to eq(HomeController::KANBAN_PER_PAGE)
        expect(response.body).to include("Showing the newest #{HomeController::KANBAN_PER_PAGE} matching workflows")
      end
    end

    describe "filters" do
      let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets") }

      describe "state filter" do
        it "shows only open jobs when state=open" do
          open_job   = Factories.job_record(repository: repo, issue_number: 1)
          closed_job = Factories.job_record(repository: repo, issue_number: 2)
          closed_job.close!; closed_job.save!

          get dashboard_jobs_path, params: { state: "open" }
          expect(response.body).to include("#1")
          expect(response.body).not_to include("#2")
        end

        it "shows only closed jobs when state=closed" do
          open_job   = Factories.job_record(repository: repo, issue_number: 1)
          closed_job = Factories.job_record(repository: repo, issue_number: 2)
          closed_job.close!; closed_job.save!

          get dashboard_jobs_path, params: { state: "closed" }
          expect(response.body).not_to include("#1")
          expect(response.body).to include("#2")
        end

        it "shows all jobs when state is absent" do
          open_job   = Factories.job_record(repository: repo, issue_number: 1)
          closed_job = Factories.job_record(repository: repo, issue_number: 2)
          closed_job.close!; closed_job.save!

          get dashboard_jobs_path
          expect(response.body).to include("#1")
          expect(response.body).to include("#2")
        end

        it "shows only open jobs whose latest workflow failed when state=failed" do
          failed = Factories.job(repository: repo, issue_number: 1)
          failed.latest_workflow.update!(state: "failed", created_at: 3.minutes.ago)

          older_failure = Factories.job(repository: repo, issue_number: 2)
          older_failure.latest_workflow.update!(state: "failed", created_at: 3.minutes.ago)
          Workflow.create!(
            job: older_failure,
            trigger_kind: "pr_comment",
            state: "succeeded",
            created_at: 1.minute.ago
          )

          closed_failed = Factories.job(repository: repo, issue_number: 3)
          closed_failed.latest_workflow.update!(state: "failed", created_at: 3.minutes.ago)
          closed_failed.close!; closed_failed.save!

          get dashboard_jobs_path, params: { state: "failed" }
          expect(response.body).to include("#1")
          expect(response.body).not_to include("#2")
          expect(response.body).not_to include("#3")
        end

        it "shows only open jobs whose latest workflow succeeded when state=succeeded" do
          succeeded = Factories.job(repository: repo, issue_number: 1)
          succeeded.latest_workflow.update!(state: "succeeded", created_at: 3.minutes.ago)

          latest_failure = Factories.job(repository: repo, issue_number: 2)
          latest_failure.latest_workflow.update!(state: "succeeded", created_at: 3.minutes.ago)
          Workflow.create!(
            job: latest_failure,
            trigger_kind: "pr_comment",
            state: "failed",
            created_at: 1.minute.ago
          )

          closed_succeeded = Factories.job(repository: repo, issue_number: 3)
          closed_succeeded.latest_workflow.update!(state: "succeeded", created_at: 3.minutes.ago)
          closed_succeeded.close!; closed_succeeded.save!

          get dashboard_jobs_path, params: { state: "succeeded" }
          expect(response.body).to include("#1")
          expect(response.body).not_to include("#2")
          expect(response.body).not_to include("#3")
        end
      end

      describe "repository filter" do
        it "shows only jobs for the selected repository" do
          repo_a = Factories.repository(user: user, owner: "acme", name: "alpha")
          repo_b = Factories.repository(user: user, owner: "acme", name: "beta")
          Factories.job_record(repository: repo_a, issue_number: 10)
          Factories.job_record(repository: repo_b, issue_number: 20)

          get dashboard_jobs_path, params: { repository_id: repo_a.id }
          expect(response.body).to include("#10")
          expect(response.body).not_to include("#20")
        end
      end

      describe "kind filter" do
        it "exposes the Direct kind value in the chip-bar schema" do
          # Legacy <select name='kind'> dropdown has been replaced by
          # the chip-bar's kind chip; its value list ships in the
          # serialized schema. Each value is humanized for display.
          get dashboard_jobs_path

          schema_attr = Nokogiri::HTML(response.body).at_css("[data-chip-bar-schema-value]")&.[]("data-chip-bar-schema-value")
          schema = JSON.parse(schema_attr)
          kind_chip = schema.find { |c| c["field"] == "kind" }
          labels = kind_chip["values"].map { |v| v["label"] }

          expect(labels).to include("Issue", "Direct", "Cron")
        end

        it "shows only direct jobs when kind=direct" do
          issue = Factories.job_record(repository: repo, issue_number: 1)
          direct = Factories.job_record(
            repository: repo,
            kind: "direct",
            issue_number: nil,
            issue_title: "Direct cleanup",
            issue_body: "Tidy the thing."
          )

          get dashboard_jobs_path, params: { kind: "direct" }

          expect(response.body).not_to include("##{issue.issue_number}")
          expect(response.body).to include("Direct cleanup")
          expect(response.body).to include(job_path(direct))
        end
      end

      describe "PR filter" do
        it "shows only jobs with a PR when pr=has_pr" do
          with    = Factories.job_record(repository: repo, issue_number: 1)
          without = Factories.job_record(repository: repo, issue_number: 2)
          with.update!(pr_number: 99)

          get dashboard_jobs_path, params: { pr: "has_pr" }
          expect(response.body).to include("#1")
          expect(response.body).not_to include("#2")
        end

        it "shows only jobs without a PR when pr=no_pr" do
          with    = Factories.job_record(repository: repo, issue_number: 1)
          without = Factories.job_record(repository: repo, issue_number: 2)
          with.update!(pr_number: 99)

          get dashboard_jobs_path, params: { pr: "no_pr" }
          expect(response.body).not_to include("#1")
          expect(response.body).to include("#2")
        end

        it "includes jobs with external_pr_number in has_pr results" do
          external = Factories.job_record(repository: repo, issue_number: 5,
                                          state: "closed", closure_reason: "preempted",
                                          external_pr_number: 7, finished_at: Time.current)
          get dashboard_jobs_path, params: { pr: "has_pr" }
          expect(response.body).to include("#5")
        end
      end

      describe "age filter" do
        it "shows only jobs created within the last day when age=1d" do
          recent = Factories.job_record(repository: repo, issue_number: 1)
          old    = Factories.job_record(repository: repo, issue_number: 2)
          old.update_column(:created_at, 2.days.ago)

          get dashboard_jobs_path, params: { age: "1d" }
          expect(response.body).to include("#1")
          expect(response.body).not_to include("#2")
        end

        it "shows only jobs created within the last 7 days when age=7d" do
          recent = Factories.job_record(repository: repo, issue_number: 1)
          old    = Factories.job_record(repository: repo, issue_number: 2)
          old.update_column(:created_at, 8.days.ago)

          get dashboard_jobs_path, params: { age: "7d" }
          expect(response.body).to include("#1")
          expect(response.body).not_to include("#2")
        end

        it "shows only jobs created within the last 30 days when age=30d" do
          recent = Factories.job_record(repository: repo, issue_number: 1)
          old    = Factories.job_record(repository: repo, issue_number: 2)
          old.update_column(:created_at, 31.days.ago)

          get dashboard_jobs_path, params: { age: "30d" }
          expect(response.body).to include("#1")
          expect(response.body).not_to include("#2")
        end

        it "ignores an unrecognised age value and shows all jobs" do
          Factories.job_record(repository: repo, issue_number: 1)
          get dashboard_jobs_path, params: { age: "bogus" }
          expect(response.body).to include("#1")
        end
      end

      describe "combined filters" do
        it "applies state and repository filters together" do
          repo_a = Factories.repository(user: user, owner: "acme", name: "alpha")
          repo_b = Factories.repository(user: user, owner: "acme", name: "beta")

          open_a  = Factories.job_record(repository: repo_a, issue_number: 1)
          closed_a = Factories.job_record(repository: repo_a, issue_number: 2)
          closed_a.close!; closed_a.save!
          open_b  = Factories.job_record(repository: repo_b, issue_number: 3)

          get dashboard_jobs_path, params: { state: "open", repository_id: repo_a.id }
          expect(response.body).to include("#1")
          expect(response.body).not_to include("#2")
          expect(response.body).not_to include("#3")
        end
      end

      describe "tag filter" do
        it "shows jobs matching any selected tag" do
          first = Factories.job_record(repository: repo, issue_number: 1)
          second = Factories.job_record(repository: repo, issue_number: 2)
          third = Factories.job_record(repository: repo, issue_number: 3)
          urgent = Factories.tag(user: user, name: "urgent", color: "red")
          auth = Factories.tag(user: user, name: "area:auth", color: "blue")
          first.tags << urgent
          second.tags << auth

          get dashboard_jobs_path, params: { tag_ids: [ urgent.id, auth.id ] }

          expect(response.body).to include("#1")
          expect(response.body).to include("#2")
          expect(response.body).not_to include("#3")
          expect(response.body).to include("urgent")
          expect(response.body).to include("area:auth")
        end
      end
    end

    describe "smart folders" do
      let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets") }

      it "renders built-in attention folders with counts" do
        # "Awaiting your approval" is `:when_present` — it only
        # appears in the sidebar if there's at least one Job in
        # `implemented` state. Set one up so the folder rendering
        # path that surfaces it is exercised. Also create an
        # invalid + an awaiting_epic Job so the high-priority
        # when_present folders show up.
        failed = Factories.job(repository: repo, issue_number: 1)
        failed.latest_workflow.update!(state: "failed", finished_at: Time.current)
        failed.initial_run.update!(state: "failed", finished_at: Time.current)
        Factories.job(repository: repo, issue_number: 2)
        awaiting_approval = Factories.job(repository: repo, issue_number: 3)
        awaiting_approval.update_columns(state: "implemented")
        Factories.job_record(repository: repo, issue_number: 4, state: "triaging",
                              validity: "duplicate", invalidation_reason: "covered")
        Factories.job_record(repository: repo, issue_number: 5, state: "triaging",
                              triaging_reason: "pending_epic_ref")

        get dashboard_jobs_path

        document = Nokogiri::HTML(response.body)
        attention = document.at_css("aside")
        # Always-visible + populated when_present folders.
        expect(attention.text).to include("Inbox", "Awaiting your approval", "Just failed", "Invalid", "Awaiting Epic")
        # Retired folders are gone.
        expect(attention.text).not_to include("In review")
        expect(attention.text).not_to include("Needs review")
        expect(attention.text).not_to include("Awaiting your move")
        # On-demand folders still live behind the "More" disclosure.
        expect(attention.text).to include("More", "Merged this week")
        expect(attention.css("a").find { |link| link.text.include?("Just failed") }.text).to include("1")
      end

      it "tucks on-demand folders into a More disclosure that closes by default" do
        Factories.job(repository: repo, issue_number: 1)

        get dashboard_jobs_path

        document = Nokogiri::HTML(response.body)
        details = document.at_css("aside details")
        expect(details).to be_present
        expect(details["open"]).to be_nil
        # Post-cleanup: only Merged this week is on_demand. Invalid
        # and Awaiting Epic moved out to :when_present.
        expect(details.text).to include("Merged this week")
        expect(details.text).not_to include("Awaiting Epic")
        expect(details.text).not_to include("Needs review")
        expect(details.text).not_to include("Invalid")
      end

      it "auto-opens the More disclosure when an on-demand folder is active" do
        Factories.job(repository: repo, issue_number: 1)
        SmartFolder.ensure_builtins!
        merged_this_week = SmartFolder.find_by!(name: "Merged this week")

        get dashboard_jobs_path, params: { smart_folder_id: merged_this_week.id }

        details = Nokogiri::HTML(response.body).at_css("aside details")
        expect(details["open"]).not_to be_nil
      end

      it "shows implemented jobs in Awaiting your approval with a live count" do
        awaiting = Factories.job_record(
          repository: repo,
          issue_number: 6,
          state: "implemented",
          issue_title: "Inspect the marble"
        )
        Factories.job_record(
          repository: repo,
          issue_number: 7,
          state: "approved",
          issue_title: "Already blessed"
        )
        SmartFolder.ensure_builtins!
        awaiting_approval = SmartFolder.find_by!(name: "Awaiting your approval")

        get dashboard_jobs_path, params: { smart_folder_id: awaiting_approval.id }

        expect(response.body).to include("Inspect the marble")
        expect(response.body).not_to include("Already blessed")
        link = Nokogiri::HTML(response.body).at_css("aside").css("a").find { |node| node.text.include?("Awaiting your approval") }
        expect(link.text).to include("1")

        awaiting.approve!(via: "operator", by_user: user)
        get dashboard_jobs_path, params: { smart_folder_id: awaiting_approval.id }

        expect(response.body).not_to include("Inspect the marble")
      end

      it "shows triaging jobs pending an epic ref in Awaiting Epic until they leave triaging" do
        pending = Factories.job_record(
          repository: repo,
          issue_number: 3,
          state: "triaging",
          triaging_reason: "pending_epic_ref",
          issue_title: "Waiting for the great parent"
        )
        Factories.job_record(
          repository: repo,
          issue_number: 4,
          state: "blocked_by_epic",
          triaging_reason: "pending_epic_ref",
          issue_title: "Parent arrived"
        )
        SmartFolder.ensure_builtins!
        awaiting_epic = SmartFolder.find_by!(name: "Awaiting Epic")

        get dashboard_jobs_path, params: { smart_folder_id: awaiting_epic.id }

        expect(response.body).to include("#3")
        expect(response.body).to include("Waiting for the great parent")
        expect(response.body).not_to include("#4")
        expect(response.body).not_to include("Parent arrived")

        pending.update!(state: "blocked_by_epic")
        get dashboard_jobs_path, params: { smart_folder_id: awaiting_epic.id }

        expect(response.body).not_to include("#3")
      end

      it "shows invalid jobs in the Invalid folder with evidence and lets the operator mark them valid" do
        job = Factories.job_record(
          repository: repo,
          issue_number: 5,
          state: "triaging",
          validity: "duplicate",
          invalidation_reason: "Covered by the ancient scroll.",
          invalidation_evidence: [ "https://github.com/acme/widgets/pull/12" ],
          issue_title: "Rebuild the aqueduct"
        )
        SmartFolder.ensure_builtins!
        invalid_folder = SmartFolder.find_by!(name: "Invalid")

        get dashboard_jobs_path, params: { smart_folder_id: invalid_folder.id }

        expect(response.body).to include("Rebuild the aqueduct")
        expect(response.body).to include("Covered by the ancient scroll.")
        expect(response.body).to include("https://github.com/acme/widgets/pull/12")
        expect(response.body).to include("Override (mark valid)")

        expect {
          post mark_valid_job_path(job), headers: { "HTTP_REFERER" => dashboard_jobs_path(smart_folder_id: invalid_folder.id) }
        }.to change { job.reload.state }.from("triaging").to("queued")
          .and change { job.runs.count }.from(0).to(1)

        expect(job.validity).to eq("valid")
        expect(job.invalidation_reason).to be_nil
        expect(job.invalidation_evidence).to eq([])

        get dashboard_jobs_path, params: { smart_folder_id: invalid_folder.id }
        expect(response.body).not_to include("Rebuild the aqueduct")
      end

      it "shows ready epics in the Inbox folder until they enter progress" do
        # The "Awaiting your move" folder was retired; the Inbox folder
        # is the current trigger for the home page's
        # "Epics awaiting your move" section (controller gates this on
        # folder_uses_attention?("inbox")).
        ready = Factories.epic(user: user, repository: repo, state: "ready", title: "Restore the forum")
        Factories.epic(user: user, repository: repo, state: "in_progress", title: "Already marching")
        SmartFolder.ensure_builtins!
        inbox = SmartFolder.find_builtin_by_attention("inbox")

        get dashboard_jobs_path, params: { smart_folder_id: inbox.id }

        # Scope assertions to the Epic table — Epic titles also appear
        # in the chip-bar schema's epic_id value list, which would
        # otherwise spuriously match the not_to include checks. The
        # heading "Epics awaiting your move" sits in a header div
        # adjacent to a sibling <table> inside the same wrapper div.
        document = Nokogiri::HTML(response.body)
        epic_section = document.at_xpath("//h2[normalize-space()='Epics awaiting your move']/ancestor::div[contains(@class,'bg-white')][1]")
        expect(epic_section).not_to be_nil
        expect(epic_section.text).to include("Restore the forum")
        expect(epic_section.text).not_to include("Already marching")

        ready.in_progress!
        get dashboard_jobs_path, params: { smart_folder_id: inbox.id }

        epic_section_after = Nokogiri::HTML(response.body)
                                     .at_xpath("//h2[normalize-space()='Epics awaiting your move']/ancestor::div[contains(@class,'bg-white')][1]")
        expect(epic_section_after.to_s).not_to include("Restore the forum") if epic_section_after
      end

      it "updates an Epic auto-approval rule from the Epics dashboard" do
        epic = Factories.epic(user: user, repository: repo, state: "ready", title: "Polish aqueduct")
        SmartFolder.ensure_builtins!
        inbox = SmartFolder.find_builtin_by_attention("inbox")

        get dashboard_jobs_path, params: { smart_folder_id: inbox.id }
        expect(response.body).to include("Auto-approval")
        expect(response.body).to include("If graders pass")

        patch dashboard_epic_auto_approval_path(epic), params: {
          epic: { auto_approve_mode: "if_graders_pass" }
        }

        expect(response).to redirect_to(dashboard_epics_path)
        expect(epic.reload.auto_approve_mode).to eq("if_graders_pass")
      end

      it "renders a Kanban card menu action that opens the dependency graph drawer" do
        # root_path redirects to chat now; the dashboard with the
        # Epics-aware Inbox folder is where the drawer lives.
        epic = Factories.epic(user: user, repository: repo, state: "ready", title: "Restore the forum")
        SmartFolder.ensure_builtins!
        inbox = SmartFolder.find_builtin_by_attention("inbox")

        get dashboard_jobs_path, params: { smart_folder_id: inbox.id }

        document = Nokogiri::HTML(response.body)
        graph_link = document.at_css("a[href='#{graph_epic_path(epic, drawer: 1)}']")

        expect(response.body).to include('data-controller="epic-graph-drawer"')
        expect(response.body).to include('aria-label="Epic dependency graph drawer"')
        expect(document.at_css("turbo-frame#epic_graph_drawer_body")).to be_present
        expect(graph_link.text).to include("Show dependency graph")
        expect(graph_link["data-turbo-frame"]).to eq("epic_graph_drawer_body")
        expect(graph_link["data-action"]).to include("epic-graph-drawer#open")
      end

      it "applies a built-in smart folder filter" do
        failed = Factories.job(repository: repo, issue_number: 1)
        failed.initial_run.update!(state: "failed", finished_at: Time.current)
        Factories.job(repository: repo, issue_number: 2)
        SmartFolder.ensure_builtins!
        just_failed = SmartFolder.find_by!(name: "Just failed")

        get dashboard_jobs_path, params: { smart_folder_id: just_failed.id }

        expect(response.body).to include("#1")
        expect(response.body).not_to include("#2")
        expect(response.body).not_to include("Showing smart folder")
      end

      it "saves the current filters as a user-defined smart folder" do
        post smart_folders_path, params: {
          state: "open",
          pr: "has_pr",
          smart_folder: { name: "Open PRs" }
        }

        folder = user.smart_folders.find_by!(name: "Open PRs")
        expect(folder.filter).to eq(
          "and" => [
            { "field" => "state", "op" => "is", "value" => "open" },
            { "field" => "pr_present", "op" => "is", "value" => "has" }
          ]
        )
        expect(response).to redirect_to(dashboard_jobs_path(smart_folder_id: folder.id))
      end

      it "shows and applies user-defined smart folders in the sidebar" do
        with_pr = Factories.job_record(repository: repo, issue_number: 1, pr_number: 9)
        without_pr = Factories.job_record(repository: repo, issue_number: 2)
        folder = user.smart_folders.create!(
          name: "PRs",
          kind: "user_defined",
          filter: { "and" => [ { "field" => "pr_present", "op" => "is", "value" => "has" } ] },
          position: 0
        )

        get dashboard_jobs_path, params: { smart_folder_id: folder.id }

        expect(response.body).to include("PRs")
        expect(response.body).to include("#1")
        expect(response.body).not_to include("#2")
      end
    end

    describe "filter memory controller" do
      let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets") }

      def run_filter_memory_controller(search:, stored: "pr=has_pr")
        script = <<~JS
          import fs from "node:fs"

          const source = fs.readFileSync("#{Rails.root.join('app/javascript/controllers/filter_memory_controller.js')}", "utf8")
            .replace('import { Controller } from "@hotwired/stimulus"', 'class Controller {}')
          const url = `data:text/javascript;base64,${Buffer.from(source).toString("base64")}`
          const mod = await import(url)
          const events = []
          let stored = #{stored.to_json}

          globalThis.window = {
            location: {
              search: #{search.to_json},
              replace: (url) => events.push(["replace", url])
            }
          }
          globalThis.sessionStorage = {
            getItem: () => stored,
            setItem: (_key, value) => {
              stored = value
              events.push(["set", value])
            },
            removeItem: () => {
              stored = null
              events.push(["remove"])
            }
          }

          new mod.default().connect()
          console.log(JSON.stringify({ events, stored }))
        JS

        stdout, stderr, status = Open3.capture3("node", "--input-type=module", "-e", script)
        expect(status).to be_success, stderr
        JSON.parse(stdout)
      end

      it "attaches filter-memory controller to the chip-bar" do
        # The legacy dropdown form was data-controller="auto-submit
        # filter-memory"; the chip-bar uses "chip-bar filter-memory"
        # and broadcasts subject + storage key the same way.
        get dashboard_jobs_path
        expect(response.body).to include('data-controller="chip-bar filter-memory"')
      end

      it "attaches filter-memory#clear action to the Clear link when filters are active" do
        Factories.job_record(repository: repo, issue_number: 1)
        get dashboard_jobs_path, params: { state: "open" }
        expect(response.body).to include("filter-memory#clear")
      end

      it "does not render the Clear link (or its action) when no filters are active" do
        get dashboard_jobs_path
        expect(response.body).not_to include("filter-memory#clear")
      end

      it "clears remembered filters when the filter form submits blank filter params" do
        result = run_filter_memory_controller(search: "?state=&repository_id=&pr=&age=")

        expect(result["events"]).to eq([ [ "remove" ] ])
        expect(result["stored"]).to be_nil
      end

      it "restores remembered filters only when no filter params were submitted" do
        result = run_filter_memory_controller(search: "")

        expect(result["events"]).to eq([ [ "replace", "/dashboard/jobs?pr=has_pr" ] ])
        expect(result["stored"]).to eq("pr=has_pr")
      end

      it "does not restore remembered filters while viewing a smart folder" do
        result = run_filter_memory_controller(search: "?smart_folder_id=1")

        expect(result["events"]).to eq([])
        expect(result["stored"]).to eq("pr=has_pr")
      end
    end

    describe "rate limit banner" do
      def set_rate_limit(remaining:, limit: 5000, resource: "core")
        user.update_columns(
          gh_rate_limit_remaining:  remaining,
          gh_rate_limit_limit:      limit,
          gh_rate_limit_reset_at:   1.hour.from_now,
          gh_rate_limit_resource:   resource,
          gh_rate_limit_observed_at: Time.current
        )
      end

      it "shows a warning banner when remaining quota is below 200" do
        set_rate_limit(remaining: 150)
        get dashboard_jobs_path
        expect(response.body).to include("quota low")
        expect(response.body).to include("150")
      end

      it "shows a critical banner when quota is exhausted" do
        set_rate_limit(remaining: 0)
        get dashboard_jobs_path
        expect(response.body).to include("exhausted")
      end

      it "shows no banner when quota is ample (>= 200)" do
        set_rate_limit(remaining: 4000)
        get dashboard_jobs_path
        expect(response.body).not_to include("quota low")
        expect(response.body).not_to include("exhausted")
      end

      it "shows no banner when no rate limit data has been recorded yet" do
        get dashboard_jobs_path
        expect(response.body).not_to include("quota low")
        expect(response.body).not_to include("exhausted")
      end
    end

    describe "archived repositories" do
      let(:active_repo)   { Factories.repository(user: user, owner: "acme", name: "active-thing") }
      let(:archived_repo) { Factories.repository(user: user, owner: "acme", name: "archived-thing").tap(&:archive!) }
      let!(:active_job)   { Factories.job(repository: active_repo,   issue_number: 1) }
      let!(:archived_job) { Factories.job(repository: archived_repo, issue_number: 2) }

      it "hides jobs from archived repositories" do
        get dashboard_jobs_path
        expect(response.body).to     include("active-thing")
        expect(response.body).not_to include("archived-thing")
      end

      it "hides workflows from archived repositories" do
        get dashboard_workflows_path
        expect(response.body).to     include("active-thing")
        expect(response.body).not_to include("archived-thing")
      end

      it "drops archived repos from the repository filter dropdown" do
        get dashboard_jobs_path
        expect(response.body).to     include(active_repo.slug)
        expect(response.body).not_to include("acme/archived-thing")
      end
    end
  end
end
