require "rails_helper"

RSpec.describe "Repositories", type: :request do
  let(:user)  { Factories.user }
  let(:other) { Factories.user }

  it "requires authentication on index" do
    user  # force a User to exist; first-run setup redirects to new_user instead
    get repositories_path
    expect(response).to redirect_to(new_session_path)
  end

  context "signed in" do
    before { sign_in_as(user) }

    it "lists only the current user's repositories" do
      mine = Factories.repository(user: user, owner: "acme", name: "widgets")
      Factories.repository(user: other, owner: "globex", name: "things")

      get repositories_path
      expect(response.body).to include("acme/widgets")
      expect(response.body).not_to include("globex/things")
    end

    it "creates with valid params" do
      expect {
        post repositories_path, params: { repository: {
          owner: "acme", name: "widgets", default_branch: "main",
          trigger_label: "syrus", polling_enabled: "1", prepare_enabled: "0", agent_provider: "codex",
          github_owner_id: "123", github_repository_id: "456"
        } }
      }.to change(user.repositories, :count).by(1)
      expect(response).to redirect_to(repositories_path)
      expect(user.repositories.last.agent_provider).to eq("codex")
      expect(user.repositories.last.prepare_enabled).to be(false)
      expect(user.repositories.last.github_owner_id).to eq(123)
      expect(user.repositories.last.github_repository_id).to eq(456)
    end

    it "updates the repository default agent and shows it on the index" do
      mine = Factories.repository(user: user, owner: "acme", name: "widgets")

      patch repository_path(mine), params: { repository: {
        owner: "acme", name: "widgets", default_branch: "main",
        trigger_label: "syrus", polling_enabled: "1", prepare_enabled: "0", agent_provider: "codex"
      } }

      expect(response).to redirect_to(repositories_path)
      expect(mine.reload.agent_provider).to eq("codex")
      expect(mine.prepare_enabled).to be(false)

      follow_redirect!
      expect(response.body).to include("agent Codex")
    end

    it "re-renders new on validation failure" do
      post repositories_path, params: { repository: { owner: "bad owner", name: "" } }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("can")  # error messages present
    end

    describe "credential mode banner" do
      it "shows installed App status without a warning banner" do
        AppSetting.current.update!(github_app_id: 123, github_app_slug: "operator-syrus")
        installation = Factories.installation(user: user, account_login: "acme")
        repo = Factories.repository(user: user, owner: "acme", name: "widgets", installation: installation)

        get repository_path(repo)

        expect(response.body).to include("✓ Syrus App installed (via acme)")
        expect(response.body).not_to include("This repository is using personal-token fallback.")
      end

      it "shows a one-click install link when the App is registered but not installed" do
        AppSetting.current.update!(github_app_id: 123, github_app_slug: "operator-syrus")
        repo = Factories.repository(
          user: user,
          owner: "acme",
          name: "widgets",
          github_owner_id: 100,
          github_repository_id: 200
        )

        get repository_path(repo)

        expect(response.body).to include("This repository is using personal-token fallback.")
        expect(response.body).to include(
          "https://github.com/apps/operator-syrus/installations/new/permissions?target_id=100&amp;repository_ids[]=200"
        )
      end

      it "shows the manifest CTA when the App is not registered" do
        repo = Factories.repository(user: user)

        get repository_path(repo)

        expect(response.body).to include("Syrus App is not registered.")
        expect(response.body).to include("Register Syrus App")
      end

      it "shows PAT fallback when the recorded installation was removed" do
        AppSetting.current.update!(github_app_id: 123, github_app_slug: "operator-syrus")
        installation = Factories.installation(user: user, account_login: "acme", removed_at: Time.current)
        repo = Factories.repository(
          user: user,
          owner: "acme",
          name: "widgets",
          github_owner_id: 100,
          github_repository_id: 200
        )
        repo.update_column(:installation_id, installation.id)

        get repository_path(repo)

        expect(response.body).to include("Its previous installation was removed.")
        expect(response.body).to include("Install Syrus App on this repository")
      end
    end

    it "scopes edit/update to the current user's repos" do
      foreign = Factories.repository(user: other, owner: "globex", name: "things")

      get edit_repository_path(foreign)
      expect(response).to have_http_status(:not_found).or redirect_to(repositories_path)
    end

    it "has no destroy route — Archive is the only retire path" do
      mine = Factories.repository(user: user)
      # DELETE /repositories/:id is no longer routable (resources
      # uses except: [:destroy]); the request 404s and the row stays.
      expect {
        delete "/repositories/#{mine.id}" rescue nil
      }.not_to change(user.repositories, :count)
    end

    it "manual poll enqueues PollRepositoryJob with force: true" do
      mine = Factories.repository(user: user, polling_enabled: false)
      expect {
        post poll_repository_path(mine)
      }.to have_enqueued_job(PollRepositoryJob).with(mine.id, force: true)
      expect(response).to redirect_to(repository_path(mine))
      expect(flash[:notice]).to match(/Polling/)
    end

    describe "archive / unarchive" do
      it "archive stamps archived_at + flips polling off" do
        mine = Factories.repository(user: user, polling_enabled: true)
        post archive_repository_path(mine)
        expect(response).to redirect_to(repositories_path)
        expect(mine.reload).to be_archived
        expect(mine.polling_enabled).to be false
      end

      it "unarchive clears archived_at" do
        mine = Factories.repository(user: user)
        mine.archive!
        post unarchive_repository_path(mine)
        expect(response).to redirect_to(repositories_path)
        expect(mine.reload).not_to be_archived
      end

      it "archive/unarchive on another user's repo is not found" do
        foreign = Factories.repository(user: other)
        post archive_repository_path(foreign)
        expect(response).to have_http_status(:not_found).or redirect_to(repositories_path)
      end

      it "manual poll on an archived repo is rejected (does not enqueue)" do
        mine = Factories.repository(user: user)
        mine.archive!
        expect {
          post poll_repository_path(mine)
        }.not_to have_enqueued_job(PollRepositoryJob)
        expect(response).to redirect_to(repositories_path)
        expect(flash[:alert]).to match(/archived/)
      end

      it "index splits active and archived repositories" do
        active   = Factories.repository(user: user, owner: "active",   name: "one")
        archived = Factories.repository(user: user, owner: "archived", name: "two")
        archived.archive!

        get repositories_path
        expect(response.body).to include("active/one")
        expect(response.body).to include("archived/two")
        expect(response.body).to match(/Archived\s*\(\s*1\s*\)/)
      end
    end

    describe "POST /repositories/:id/retry_failed_jobs" do
      let(:repo) { Factories.repository(user: user) }

      def fail_latest_run!(job)
        run = job.current_run
        run.update!(state: "failed", finished_at: Time.current)
      end

      it "spawns a Retry workflow for each failed open Job and counts them" do
        failed_a = Factories.job(repository: repo, issue_number: 1)
        failed_b = Factories.job(repository: repo, issue_number: 2)
        succeeded = Factories.job(repository: repo, issue_number: 3)
        running   = Factories.job(repository: repo, issue_number: 4)
        closed    = Factories.job(repository: repo, issue_number: 5)

        fail_latest_run!(failed_a)
        fail_latest_run!(failed_b)
        succeeded.current_run.update!(state: "succeeded", finished_at: Time.current)
        running.current_run.update!(state: "running", started_at: Time.current)
        closed.close!; closed.save!

        expect {
          post retry_failed_jobs_repository_path(repo)
        }.to change { Workflow.where(trigger_kind: "retry").count }.by(2)

        expect(response).to redirect_to(repository_path(repo))
        expect(flash[:notice]).to match(/2 failed jobs/)
      end

      it "uses the current user's preferred agent and persists it on each retried Job" do
        failed_a = Factories.job(repository: repo, issue_number: 1)
        failed_b = Factories.job(repository: repo, issue_number: 2)
        fail_latest_run!(failed_a)
        fail_latest_run!(failed_b)
        user.update!(agent_provider: "codex", codex_auth_mode: "api_key", codex_api_key: "sk-test")

        post retry_failed_jobs_repository_path(repo)

        [ failed_a, failed_b ].each do |failed_job|
          retry_workflow = failed_job.reload.workflows.where(trigger_kind: "retry").last
          expect(failed_job.agent_provider).to eq("codex")
          expect(retry_workflow.agent_provider).to eq("codex")
          expect(retry_workflow.first_step.runs.last.agent_provider).to eq("codex")
        end
        expect(flash[:notice]).to match(/with Codex/)
      end

      it "uses the repository default agent when one is specified" do
        repo.update!(agent_provider: "codex")
        failed_a = Factories.job(repository: repo, issue_number: 1)
        failed_b = Factories.job(repository: repo, issue_number: 2)
        fail_latest_run!(failed_a)
        fail_latest_run!(failed_b)

        post retry_failed_jobs_repository_path(repo)

        [ failed_a, failed_b ].each do |failed_job|
          retry_workflow = failed_job.reload.workflows.where(trigger_kind: "retry").last
          expect(failed_job.agent_provider).to eq("codex")
          expect(retry_workflow.agent_provider).to eq("codex")
          expect(retry_workflow.first_step.runs.last.agent_provider).to eq("codex")
        end
        expect(flash[:notice]).to match(/with Codex/)
      end

      it "returns an alert when no Jobs need retrying" do
        Factories.job(repository: repo, issue_number: 1)  # has only a queued initial run
        post retry_failed_jobs_repository_path(repo)
        expect(flash[:alert]).to match(/No failed jobs/)
      end

      it "scopes to the current user (other user's repo is 404)" do
        foreign = Factories.repository(user: other)
        post retry_failed_jobs_repository_path(foreign)
        expect(response).to have_http_status(:not_found).or redirect_to(repositories_path)
      end
    end

    describe "GET /repositories/owners" do
      it "returns user and orgs when token is present" do
        allow(GithubClient).to receive(:for_user).and_return(
          instance_double(GithubClient, accessible_owners: { user: "john", orgs: %w[org-a] })
        )
        get owners_repositories_path, headers: { "Accept" => "application/json" }
        expect(response).to have_http_status(:ok)
        body = JSON.parse(response.body)
        expect(body["user"]).to eq("john")
        expect(body["orgs"]).to eq([ "org-a" ])
      end

      it "returns no_token error when user has no github token" do
        allow(GithubClient).to receive(:for_user).and_raise(ArgumentError)
        get owners_repositories_path, headers: { "Accept" => "application/json" }
        expect(JSON.parse(response.body)["error"]).to eq("no_token")
      end
    end

    describe "GET /repositories/repos" do
      it "returns sorted repo names for a valid owner" do
        allow(GithubClient).to receive(:for_user).and_return(
          instance_double(GithubClient, owner_repos: %w[alpha beta])
        )
        get repos_repositories_path, params: { owner: "john", owner_type: "user" },
            headers: { "Accept" => "application/json" }
        expect(response).to have_http_status(:ok)
        body = JSON.parse(response.body)
        expect(body["repos"]).to eq(%w[alpha beta])
      end

      it "returns missing_params error when owner is blank" do
        get repos_repositories_path, headers: { "Accept" => "application/json" }
        expect(JSON.parse(response.body)["error"]).to eq("missing_params")
      end

      it "returns not_found error when GitHub returns 404" do
        allow(GithubClient).to receive(:for_user).and_return(
          instance_double(GithubClient).tap { |d| allow(d).to receive(:owner_repos).and_raise(Octokit::NotFound) }
        )
        get repos_repositories_path, params: { owner: "ghost" },
            headers: { "Accept" => "application/json" }
        expect(JSON.parse(response.body)["error"]).to eq("not_found")
      end
    end

    describe "GET /repositories/:id" do
      it "requires authentication" do
        # tested via the outer unauthenticated context below
      end

      it "renders the show page" do
        mine = Factories.repository(user: user, owner: "acme", name: "widgets")
        get repository_path(mine)
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("acme/widgets")
      end

      it "shows the repository default agent on the show page" do
        mine = Factories.repository(user: user, agent_provider: "codex")
        get repository_path(mine)
        expect(response.body).to include("Agent:")
        expect(response.body).to include("Codex")
      end

      it "labels retry failed with the repository default agent" do
        mine = Factories.repository(user: user, agent_provider: "codex")
        failed = Factories.job(repository: mine)
        failed.current_run.update!(state: "failed", finished_at: Time.current)

        get repository_path(mine)

        expect(response.body).to include("Retry 1 failed with Codex")
        expect(response.body).to include("Retry 1 failed job(s) with Codex?")
      end

      it "shows only jobs belonging to this repository" do
        mine  = Factories.repository(user: user, owner: "acme", name: "widgets")
        other = Factories.repository(user: user, owner: "acme", name: "other")
        job_mine  = Factories.job(repository: mine)
        job_other = Factories.job(repository: other)

        get repository_path(mine)
        expect(response.body).to include(job_path(job_mine))
        expect(response.body).not_to include(job_path(job_other))
      end

      it "does not show another user's repository" do
        foreign = Factories.repository(user: other, owner: "globex", name: "things")
        get repository_path(foreign)
        expect(response).to have_http_status(:not_found)
      end

      it "links the slug to GitHub" do
        mine = Factories.repository(user: user, owner: "acme", name: "widgets")
        get repository_path(mine)
        expect(response.body).to include("https://github.com/acme/widgets")
      end

      describe "tabs" do
        let(:repo) { Factories.repository(user: user) }

        it "defaults to the overview tab" do
          get repository_path(repo)
          expect(response).to have_http_status(:ok)
          expect(response.body).to include("Overview")
          expect(response.body).to include("GitHub Issues")
          expect(response.body).to include("Recent jobs")
        end

        it "renders the github_issues tab and fetches issues" do
          fake_issue = double("issue",
            number: 42, title: "Fix the thing", html_url: "https://github.com/test/repo/issues/42",
            body: "description", state: "open", labels: [], user: nil,
            created_at: 1.day.ago)
          allow(GithubClient).to receive(:for).and_return(
            instance_double(GithubClient, list_all_issues: [ fake_issue ])
          )

          get repository_path(repo, tab: "github_issues")
          expect(response).to have_http_status(:ok)
          expect(response.body).to include("Fix the thing")
          expect(response.body).not_to include("Recent jobs")
        end

        it "shows an alert on the github_issues tab when no token is configured" do
          allow(GithubClient).to receive(:for).and_raise(ArgumentError)

          get repository_path(repo, tab: "github_issues")
          expect(response).to have_http_status(:ok)
          expect(flash[:alert]).to match(/No GitHub token/)
        end

        it "shows an alert on the github_issues tab when GitHub returns an error" do
          allow(GithubClient).to receive(:for).and_return(
            instance_double(GithubClient).tap { |d|
              allow(d).to receive(:list_all_issues).and_raise(Octokit::Forbidden)
            }
          )

          get repository_path(repo, tab: "github_issues")
          expect(response).to have_http_status(:ok)
          expect(flash[:alert]).to match(/GitHub error/)
        end

        it "ignores unknown tab values and falls back to overview" do
          get repository_path(repo, tab: "hax")
          expect(response).to have_http_status(:ok)
          expect(response.body).to include("Recent jobs")
        end
      end

      describe "pagination" do
        let(:repo) { Factories.repository(user: user) }

        it "shows no pagination controls when jobs fit on one page" do
          3.times { |i| Factories.job(repository: repo, issue_number: i + 1) }
          get repository_path(repo)
          expect(response.body).not_to include("← Previous")
          expect(response.body).not_to include("Next →")
        end

        it "shows 'Showing X–Y of Z' counter and navigation when jobs exceed one page" do
          (RepositoriesController::PER_PAGE + 2).times { |i| Factories.job(repository: repo, issue_number: i + 1) }
          get repository_path(repo)
          total = RepositoriesController::PER_PAGE + 2
          expect(response.body).to include("Showing 1–#{RepositoriesController::PER_PAGE} of #{total}")
          expect(response.body).to include("Next →")
        end

        it "renders a disabled Previous button on page 1" do
          (RepositoriesController::PER_PAGE + 1).times { |i| Factories.job(repository: repo, issue_number: i + 1) }
          get repository_path(repo)
          expect(response.body).to match(/class="px-3 py-1 border border-gray-200 rounded text-gray-300"[^>]*>← Previous/)
        end

        it "renders a disabled Next button on the last page" do
          (RepositoriesController::PER_PAGE + 1).times { |i| Factories.job(repository: repo, issue_number: i + 1) }
          get repository_path(repo, page: 2)
          expect(response.body).to match(/class="px-3 py-1 border border-gray-200 rounded text-gray-300"[^>]*>Next →/)
        end

        it "shows the correct range on page 2" do
          (RepositoriesController::PER_PAGE + 3).times { |i| Factories.job(repository: repo, issue_number: i + 1) }
          get repository_path(repo, page: 2)
          total = RepositoriesController::PER_PAGE + 3
          expect(response.body).to include("Showing #{RepositoriesController::PER_PAGE + 1}–#{total} of #{total}")
        end
      end
    end
  end

  it "requires authentication on show" do
    repo = Factories.repository(user: user)
    get repository_path(repo)
    expect(response).to redirect_to(new_session_path)
  end
end
