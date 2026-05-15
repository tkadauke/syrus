require "rails_helper"
require "open3"

RSpec.describe "Dashboard", type: :request do
  let(:user)  { Factories.user }
  let(:other) { Factories.user }

  it "requires authentication" do
    user  # force a User to exist; first-run setup redirects to new_user instead
    get root_path
    expect(response).to redirect_to(new_session_path)
  end

  context "signed in" do
    before { sign_in_as(user) }

    it "lists the current user's recent jobs" do
      mine_repo = Factories.repository(user: user, owner: "acme", name: "widgets")
      Factories.job_record(repository: mine_repo, issue_number: 7)

      other_repo = Factories.repository(user: other, owner: "globex", name: "things")
      Factories.job_record(repository: other_repo, issue_number: 99)

      get root_path
      expect(response.body).to include("acme/widgets")
      expect(response.body).to include("#7")
      expect(response.body).not_to include("globex/things")
      expect(response.body).not_to include("#99")
    end

    it "shows the empty state when no jobs exist" do
      get root_path
      expect(response.body).to include("No jobs yet")
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

      get root_path

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

      get root_path

      row = Nokogiri::HTML(response.body).at_css("tbody tr")
      expect(row.css("td")[1].text).to include("$1.23")
    end

    it "merges job state details into the issue column on mobile" do
      repo = Factories.repository(user: user, owner: "acme", name: "widgets")
      job = Factories.job(repository: repo, issue_number: 7, priority: "high")
      job.initial_run.update!(state: "failed", cost_usd: 1.23)

      get root_path

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

      get root_path

      document = Nokogiri::HTML(response.body)
      pin = document.at_css("a[href='#{job_pin_path(job)}'][aria-label='Pin job']")
      expect(pin).to be_present
      expect(pin["data-turbo-method"]).to eq("post")
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
      pinned_folder = SmartFolder.builtins.find { |f| f.filter["attention"] == "pinned" }
      get root_path, params: { smart_folder_id: pinned_folder.id }

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

    it "renders an attention dropdown with every built-in smart folder's attention value" do
      Factories.repository(user: user, owner: "acme", name: "widgets")

      get root_path

      select = Nokogiri::HTML(response.body).at_css("select[name='attention']")
      expect(select).to be_present
      option_values = select.css("option").map { |o| o["value"] }
      expected = SmartFolder::BUILTIN_DEFINITIONS.filter_map { |d| d[:filter]["attention"] }
      expect(option_values).to eq([""] + expected)
    end

    it "collapses folders and filters by default on mobile only" do
      repo = Factories.repository(user: user, owner: "acme", name: "widgets")
      user.smart_folders.create!(
        name: "Open PRs",
        kind: "user_defined",
        position: 0,
        filter: { "pr" => "has_pr" }
      )
      Factories.job_record(repository: repo, issue_number: 1)

      get root_path

      document = Nokogiri::HTML(response.body)
      mobile_panel = document.at_css("details")
      desktop_sidebar = document.at_css("aside")
      desktop_filter_form = document.css("form[action='#{root_path}']").find do |form|
        form["method"] == "get" && form["class"].to_s.include?("lg:flex")
      end

      expect(mobile_panel).to be_present
      expect(mobile_panel["class"]).to include("lg:hidden")
      expect(mobile_panel["open"]).to be_nil
      expect(mobile_panel.at_css("summary").text).to include("Folders and filters")
      expect(mobile_panel.text).to include("Attention")
      expect(mobile_panel.text).to include("Open PRs")
      expect(mobile_panel.at_css("select[name='attention']")).to be_present

      expect(desktop_sidebar["class"]).to include("hidden")
      expect(desktop_sidebar["class"]).to include("lg:block")
      expect(desktop_filter_form).to be_present
    end

    it "excludes closed jobs from the inbox even when they have a failed latest run" do
      repo = Factories.repository(user: user, owner: "acme", name: "widgets")
      open_failed = Factories.job(repository: repo, issue_number: 1)
      open_failed.initial_run.update!(state: "failed", finished_at: Time.current)
      closed_failed = Factories.job(repository: repo, issue_number: 2)
      closed_failed.initial_run.update!(state: "failed", finished_at: Time.current)
      closed_failed.close!; closed_failed.save!

      get root_path, params: { attention: "inbox" }

      expect(response.body).to include("#1")
      expect(response.body).not_to include("#2")
    end

    it "filters jobs by attention=just_failed when picked from the dropdown" do
      repo = Factories.repository(user: user, owner: "acme", name: "widgets")
      failing = Factories.job(repository: repo, issue_number: 1)
      failing.initial_run.update!(state: "failed", finished_at: Time.current)
      Factories.job(repository: repo, issue_number: 2)

      get root_path, params: { attention: "just_failed" }

      expect(response.body).to include("#1")
      expect(response.body).not_to include("#2")
    end

    it "shows the pinned folder's count scoped to the user's pins, not all jobs" do
      repo = Factories.repository(user: user, owner: "acme", name: "widgets")
      pinned = Factories.job_record(repository: repo, issue_number: 1)
      4.times { |i| Factories.job_record(repository: repo, issue_number: 100 + i) }
      Factories.job_pin(user: user, job: pinned)

      SmartFolder.ensure_builtins!
      pinned_folder = SmartFolder.builtins.find { |f| f.filter["attention"] == "pinned" }
      get root_path

      sidebar = Nokogiri::HTML(response.body).at_css("aside")
      pinned_row = sidebar.css("a").find { |a| a["href"] == root_path(smart_folder_id: pinned_folder.id) }
      expect(pinned_row).to be_present
      expect(pinned_row.text).to match(/Pinned\s+1\b/)
    end

    it "hides the Pinned sidebar entry when the user has nothing pinned" do
      Factories.repository(user: user, owner: "acme", name: "widgets")

      get root_path

      sidebar = Nokogiri::HTML(response.body).at_css("aside")
      expect(sidebar.text).not_to include("Pinned")
    end

    it "keeps the Pinned sidebar entry visible when it is the active folder, even if empty" do
      Factories.repository(user: user, owner: "acme", name: "widgets")
      SmartFolder.ensure_builtins!
      pinned_folder = SmartFolder.builtins.find { |f| f.filter["attention"] == "pinned" }

      get root_path, params: { smart_folder_id: pinned_folder.id }

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

      get root_path

      sidebar = Nokogiri::HTML(response.body).at_css("aside")
      in_progress_row = sidebar.css("a").find { |a| a.text.include?("In progress") }
      expect(in_progress_row).to be_present
      expect(in_progress_row.text).to match(/In progress\s+1\b/)
    end

    it "hides the In progress folder when nothing is queued or running" do
      repo = Factories.repository(user: user, owner: "acme", name: "widgets")
      done = Factories.job(repository: repo, issue_number: 1)
      done.workflows.first.update!(state: "succeeded", started_at: 1.hour.ago, finished_at: Time.current)

      get root_path

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

      get root_path, params: { attention: "in_progress" }

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
      pinned_folder = SmartFolder.builtins.find { |f| f.filter["attention"] == "pinned" }
      get root_path, params: { smart_folder_id: pinned_folder.id, state: "closed" }

      expect(response.body).not_to include("#1")
      expect(response.body).to include("#2")
    end

    it "does not carry smart_folder_id through the filter form so manual changes break out of the folder" do
      Factories.repository(user: user, owner: "acme", name: "widgets")
      SmartFolder.ensure_builtins!
      inbox = SmartFolder.builtins.find { |f| f.filter["attention"] == "inbox" }

      get root_path, params: { smart_folder_id: inbox.id }

      document = Nokogiri::HTML(response.body)
      filter_form = document.css("form[action='#{root_path}']").find { |f| f["method"] == "get" }
      expect(filter_form).to be_present
      expect(filter_form.at_css("input[name='smart_folder_id']")).to be_nil
      # The smart folder's filters are pre-populated in the form inputs
      # so submitting the form preserves them as plain URL params.
      expect(filter_form.at_css("select[name='attention'] option[selected]")["value"]).to eq("inbox")
    end

    it "points the Clear link at root_path so it drops both filters and any active smart folder" do
      Factories.repository(user: user, owner: "acme", name: "widgets")
      SmartFolder.ensure_builtins!
      inbox = SmartFolder.builtins.find { |f| f.filter["attention"] == "inbox" }

      get root_path, params: { smart_folder_id: inbox.id, state: "open" }

      clear_link = Nokogiri::HTML(response.body).css("a").find { |a| a.text.strip == "Clear" }
      expect(clear_link).to be_present
      expect(clear_link["href"]).to eq(root_path)
    end

    it "shows up to three tag chips with overflow in job rows" do
      repo = Factories.repository(user: user, owner: "acme", name: "widgets")
      job = Factories.job_record(repository: repo, issue_number: 7)
      %w[alpha beta gamma zeta].each { |name| job.tags << Factories.tag(user: user, name: name) }

      get root_path

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

      get root_path

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

      get root_path

      document = Nokogiri::HTML(response.body)
      status_cell = document.css("tbody tr td")[1]
      latest_cell = document.css("tbody tr td")[4]

      expect(status_cell.text).to include("closed")
      expect(status_cell.text).not_to include("initial")
      expect(latest_cell.text).to include("initial")
      expect(latest_cell.text).to include("queued")
    end

    describe "bulk job actions" do
      let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets") }

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

        get root_path

        document = Nokogiri::HTML(response.body)
        expect(document.at_css("form[action='#{bulk_dashboard_jobs_path}'][data-controller='bulk-jobs']")).to be_present
        expect(document.at_css("input[aria-label='Select all jobs'][data-bulk-jobs-target='selectAll']")).to be_present
        expect(document.at_css("input[name='job_ids[]'][value='#{job.id}'][data-bulk-jobs-target='checkbox']")).to be_present
        expect(document.at_css("[data-bulk-jobs-target='actions']")["class"]).to include("hidden")
        expect(response.body).to include("Bulk actions")
        expect(response.body).to include("Retry")
        expect(response.body).to include("Close")
        expect(response.body).to include("Apply tag")
        expect(response.body).to include("epic:attachments")
      end

      it "renders all configured agent retry choices when more than one agent is configured" do
        user.update!(claude_oauth_token: "oat-test", codex_auth_mode: "api_key", codex_api_key: "sk-test")
        Factories.job(repository: repo, issue_number: 7)

        get root_path

        expect(response.body).to include("Retry with Claude")
        expect(response.body).to include("Retry with Codex")
      end

      it "does not render agent-specific retry choices with only one configured agent" do
        user.update!(claude_oauth_token: "oat-test", codex_api_key: nil)
        Factories.job(repository: repo, issue_number: 7)

        get root_path

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
        get root_path(tab: "workflows")
        expect(response.body).to include("No workflows yet")
      end

      it "lists workflows for the current user with their trigger and step caption" do
        repo = Factories.repository(user: user, owner: "acme", name: "widgets")
        Factories.job(repository: repo, issue_number: 7)
        # Job's after_create_commit instantiated a Workflows::Initial
        # — prepare → loop(implement, grade) → summarize → pr_open. Show that on
        # the Workflows tab.
        get root_path(tab: "workflows")
        expect(response.body).to include("acme/widgets")
        expect(response.body).to include("initial")              # trigger pill
        expect(response.body).to include("Prepare workspace")    # human-readable step kind label (first step now)
        expect(response.body).to include("(1/5)")                # step counter
      end

      it "merges workflow state into the issue column on mobile" do
        repo = Factories.repository(user: user, owner: "acme", name: "widgets")
        job = Factories.job(repository: repo, issue_number: 7)
        job.latest_workflow.update!(state: "running")

        get root_path(tab: "workflows")

        document = Nokogiri::HTML(response.body)
        state_header = document.css("thead th").find { |th| th.text.strip == "State" }
        row = document.at_css("tbody tr")
        mobile_state_summary = row.css("td")[3].css("[class]").find do |node|
          node["class"].to_s.include?("sm:hidden") && node.text.include?("running")
        end

        expect(state_header["class"]).to include("hidden sm:table-cell")
        expect(row.css("td")[0]["class"]).to include("hidden sm:table-cell")
        expect(mobile_state_summary.text).to include("initial")
        expect(mobile_state_summary.text).to include("acme/widgets")
      end

      it "scopes to the current user (no leakage)" do
        mine = Factories.repository(user: user, owner: "acme", name: "widgets")
        Factories.job(repository: mine, issue_number: 7)
        theirs = Factories.repository(user: other, owner: "globex", name: "things")
        Factories.job(repository: theirs, issue_number: 99)
        get root_path(tab: "workflows")
        expect(response.body).to include("acme/widgets")
        expect(response.body).not_to include("globex/things")
      end
    end

    describe "filters" do
      let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets") }

      describe "state filter" do
        it "shows only open jobs when state=open" do
          open_job   = Factories.job_record(repository: repo, issue_number: 1)
          closed_job = Factories.job_record(repository: repo, issue_number: 2)
          closed_job.close!; closed_job.save!

          get root_path, params: { state: "open" }
          expect(response.body).to include("#1")
          expect(response.body).not_to include("#2")
        end

        it "shows only closed jobs when state=closed" do
          open_job   = Factories.job_record(repository: repo, issue_number: 1)
          closed_job = Factories.job_record(repository: repo, issue_number: 2)
          closed_job.close!; closed_job.save!

          get root_path, params: { state: "closed" }
          expect(response.body).not_to include("#1")
          expect(response.body).to include("#2")
        end

        it "shows all jobs when state is absent" do
          open_job   = Factories.job_record(repository: repo, issue_number: 1)
          closed_job = Factories.job_record(repository: repo, issue_number: 2)
          closed_job.close!; closed_job.save!

          get root_path
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

          get root_path, params: { state: "failed" }
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

          get root_path, params: { state: "succeeded" }
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

          get root_path, params: { repository_id: repo_a.id }
          expect(response.body).to include("#10")
          expect(response.body).not_to include("#20")
        end
      end

      describe "kind filter" do
        it "renders Direct in the kind facet" do
          get root_path

          document = Nokogiri::HTML(response.body)
          labels = document.css("select[name='kind'] option").map(&:text)

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

          get root_path, params: { kind: "direct" }

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

          get root_path, params: { pr: "has_pr" }
          expect(response.body).to include("#1")
          expect(response.body).not_to include("#2")
        end

        it "shows only jobs without a PR when pr=no_pr" do
          with    = Factories.job_record(repository: repo, issue_number: 1)
          without = Factories.job_record(repository: repo, issue_number: 2)
          with.update!(pr_number: 99)

          get root_path, params: { pr: "no_pr" }
          expect(response.body).not_to include("#1")
          expect(response.body).to include("#2")
        end

        it "includes jobs with external_pr_number in has_pr results" do
          external = Factories.job_record(repository: repo, issue_number: 5,
                                          state: "closed", closure_reason: "preempted",
                                          external_pr_number: 7, finished_at: Time.current)
          get root_path, params: { pr: "has_pr" }
          expect(response.body).to include("#5")
        end
      end

      describe "age filter" do
        it "shows only jobs created within the last day when age=1d" do
          recent = Factories.job_record(repository: repo, issue_number: 1)
          old    = Factories.job_record(repository: repo, issue_number: 2)
          old.update_column(:created_at, 2.days.ago)

          get root_path, params: { age: "1d" }
          expect(response.body).to include("#1")
          expect(response.body).not_to include("#2")
        end

        it "shows only jobs created within the last 7 days when age=7d" do
          recent = Factories.job_record(repository: repo, issue_number: 1)
          old    = Factories.job_record(repository: repo, issue_number: 2)
          old.update_column(:created_at, 8.days.ago)

          get root_path, params: { age: "7d" }
          expect(response.body).to include("#1")
          expect(response.body).not_to include("#2")
        end

        it "shows only jobs created within the last 30 days when age=30d" do
          recent = Factories.job_record(repository: repo, issue_number: 1)
          old    = Factories.job_record(repository: repo, issue_number: 2)
          old.update_column(:created_at, 31.days.ago)

          get root_path, params: { age: "30d" }
          expect(response.body).to include("#1")
          expect(response.body).not_to include("#2")
        end

        it "ignores an unrecognised age value and shows all jobs" do
          Factories.job_record(repository: repo, issue_number: 1)
          get root_path, params: { age: "bogus" }
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

          get root_path, params: { state: "open", repository_id: repo_a.id }
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

          get root_path, params: { tag_ids: [ urgent.id, auth.id ] }

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
        failed = Factories.job(repository: repo, issue_number: 1)
        failed.initial_run.update!(state: "failed", finished_at: Time.current)
        Factories.job(repository: repo, issue_number: 2)

        get root_path

        document = Nokogiri::HTML(response.body)
        attention = document.at_css("aside")
        expect(attention.text).to include("Inbox", "Just failed", "In review", "Stale", "Blocked", "Merged this week")
        expect(attention.css("a").find { |link| link.text.include?("Just failed") }.text).to include("1")
      end

      it "applies a built-in smart folder filter" do
        failed = Factories.job(repository: repo, issue_number: 1)
        failed.initial_run.update!(state: "failed", finished_at: Time.current)
        Factories.job(repository: repo, issue_number: 2)
        SmartFolder.ensure_builtins!
        just_failed = SmartFolder.find_by!(name: "Just failed")

        get root_path, params: { smart_folder_id: just_failed.id }

        expect(response.body).to include("#1")
        expect(response.body).not_to include("#2")
        expect(response.body).to include("Showing smart folder")
      end

      it "saves the current filters as a user-defined smart folder" do
        post smart_folders_path, params: {
          state: "open",
          pr: "has_pr",
          smart_folder: { name: "Open PRs" }
        }

        folder = user.smart_folders.find_by!(name: "Open PRs")
        expect(folder.filter).to eq("state" => "open", "pr" => "has_pr")
        expect(response).to redirect_to(root_path(smart_folder_id: folder.id))
      end

      it "shows and applies user-defined smart folders in the sidebar" do
        with_pr = Factories.job_record(repository: repo, issue_number: 1, pr_number: 9)
        without_pr = Factories.job_record(repository: repo, issue_number: 2)
        folder = user.smart_folders.create!(
          name: "PRs",
          kind: "user_defined",
          filter: { "pr" => "has_pr" },
          position: 0
        )

        get root_path, params: { smart_folder_id: folder.id }

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

      it "attaches filter-memory controller to the jobs filter form" do
        get root_path
        expect(response.body).to include('data-controller="auto-submit filter-memory"')
      end

      it "attaches filter-memory#clear action to the Clear link when filters are active" do
        Factories.job_record(repository: repo, issue_number: 1)
        get root_path, params: { state: "open" }
        expect(response.body).to include("filter-memory#clear")
      end

      it "does not render the Clear link (or its action) when no filters are active" do
        get root_path
        expect(response.body).not_to include("filter-memory#clear")
      end

      it "clears remembered filters when the filter form submits blank filter params" do
        result = run_filter_memory_controller(search: "?state=&repository_id=&pr=&age=")

        expect(result["events"]).to eq([ [ "remove" ] ])
        expect(result["stored"]).to be_nil
      end

      it "restores remembered filters only when no filter params were submitted" do
        result = run_filter_memory_controller(search: "")

        expect(result["events"]).to eq([ [ "replace", "/?pr=has_pr" ] ])
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
        get root_path
        expect(response.body).to include("quota low")
        expect(response.body).to include("150")
      end

      it "shows a critical banner when quota is exhausted" do
        set_rate_limit(remaining: 0)
        get root_path
        expect(response.body).to include("exhausted")
      end

      it "shows no banner when quota is ample (>= 200)" do
        set_rate_limit(remaining: 4000)
        get root_path
        expect(response.body).not_to include("quota low")
        expect(response.body).not_to include("exhausted")
      end

      it "shows no banner when no rate limit data has been recorded yet" do
        get root_path
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
        get root_path
        expect(response.body).to     include("active-thing")
        expect(response.body).not_to include("archived-thing")
      end

      it "hides workflows from archived repositories" do
        get root_path(tab: "workflows")
        expect(response.body).to     include("active-thing")
        expect(response.body).not_to include("archived-thing")
      end

      it "drops archived repos from the repository filter dropdown" do
        get root_path
        expect(response.body).to     include(active_repo.slug)
        expect(response.body).not_to include("acme/archived-thing")
      end
    end
  end
end
