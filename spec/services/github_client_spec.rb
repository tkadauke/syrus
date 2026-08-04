require "rails_helper"

RSpec.describe GithubClient do
  let(:user) { Factories.user(github_token: "ghp_test_token") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }

  it "raises when the user has no github_token" do
    bare = Factories.user
    expect { GithubClient.new(bare) }.to raise_error(ArgumentError)
  end

  describe ".for" do
    it "uses an active installation token before the user's PAT" do
      installation = Factories.installation(
        user: user,
        cached_token: "install-token",
        cached_token_expires_at: 1.hour.from_now
      )
      repository.update!(installation: installation)
      stub = stub_request(:get, "https://api.github.com/repos/acme/widgets/issues/42")
        .with(headers: { "Authorization" => "token install-token" })
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: { number: 42, title: "Bot path" }.to_json)

      GithubClient.for(repository: repository, user: user).fetch_issue(repository.slug, 42)

      expect(stub).to have_been_requested
    end

    it "falls back to the user's PAT when the repository has no active installation" do
      installation = Factories.installation(
        user: user,
        cached_token: "install-token",
        cached_token_expires_at: 1.hour.from_now,
        removed_at: Time.current
      )
      repository.update!(installation: installation)
      stub = stub_request(:get, "https://api.github.com/repos/acme/widgets/issues/42")
        .with(headers: { "Authorization" => "token ghp_test_token" })
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: { number: 42, title: "PAT path" }.to_json)

      GithubClient.for(repository: repository, user: user).fetch_issue(repository.slug, 42)

      expect(stub).to have_been_requested
    end

    it "raises a clear error when neither installation nor PAT is available" do
      bare = Factories.user
      repo = Factories.repository(user: bare)

      expect { GithubClient.for(repository: repo) }.to raise_error(ArgumentError, /github_token/)
    end

    context "with membership-level installation" do
      it "prefers the user's membership installation over the repo-level installation" do
        repo_installation = Factories.installation(
          user: user,
          cached_token: "repo-install-token",
          cached_token_expires_at: 1.hour.from_now
        )
        repository.update!(installation: repo_installation)

        member_installation = Factories.installation(
          user: user,
          account_login: "member-acme",
          cached_token: "member-install-token",
          cached_token_expires_at: 1.hour.from_now
        )
        repository.repository_memberships.find_by!(user: user).update!(installation: member_installation)

        stub = stub_request(:get, "https://api.github.com/repos/acme/widgets/issues/42")
          .with(headers: { "Authorization" => "token member-install-token" })
          .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                     body: { number: 42, title: "Member install path" }.to_json)

        GithubClient.for(repository: repository, user: user).fetch_issue(repository.slug, 42)

        expect(stub).to have_been_requested
      end

      it "falls back to the repo-level installation when membership has none" do
        repo_installation = Factories.installation(
          user: user,
          cached_token: "repo-install-token",
          cached_token_expires_at: 1.hour.from_now
        )
        repository.update!(installation: repo_installation)
        # existing membership from seed_owner_membership already has nil installation — no change needed

        stub = stub_request(:get, "https://api.github.com/repos/acme/widgets/issues/42")
          .with(headers: { "Authorization" => "token repo-install-token" })
          .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                     body: { number: 42, title: "Repo install fallback" }.to_json)

        GithubClient.for(repository: repository, user: user).fetch_issue(repository.slug, 42)

        expect(stub).to have_been_requested
      end

      it "falls back to the user's PAT when the membership installation has been removed" do
        removed_installation = Factories.installation(
          user: user,
          account_login: "member-acme",
          cached_token: "member-install-token",
          cached_token_expires_at: 1.hour.from_now,
          removed_at: Time.current
        )
        repository.repository_memberships.find_by!(user: user).update!(installation: removed_installation)

        stub = stub_request(:get, "https://api.github.com/repos/acme/widgets/issues/42")
          .with(headers: { "Authorization" => "token ghp_test_token" })
          .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                     body: { number: 42, title: "PAT fallback" }.to_json)

        GithubClient.for(repository: repository, user: user).fetch_issue(repository.slug, 42)

        expect(stub).to have_been_requested
      end
    end
  end

  describe "installation token refresh" do
    before do
      AppSetting.current.update!(github_app_id: 123, github_app_private_key_pem: "stub-pem")
      allow(GithubAppClient).to receive(:app_jwt).and_return("app-jwt")
    end

    def stub_installation_token(token:, expires_at: 1.hour.from_now)
      stub_request(:post, "https://api.github.com/app/installations/987/access_tokens")
        .with(headers: { "Authorization" => "Bearer app-jwt" })
        .to_return(status: 201, headers: { "Content-Type" => "application/json" },
                   body: { token: token, expires_at: expires_at.iso8601 }.to_json)
    end

    it "returns the cached token when it is not near expiry" do
      installation = Factories.installation(
        user: user,
        github_installation_id: 987,
        cached_token: "cached-token",
        cached_token_expires_at: 10.minutes.from_now
      )

      expect(installation.fresh_token).to eq("cached-token")
      expect(WebMock).not_to have_requested(:post, "https://api.github.com/app/installations/987/access_tokens")
    end

    it "refreshes stale or near-expiry cached tokens" do
      stub_installation_token(token: "fresh-token")
      installation = Factories.installation(
        user: user,
        github_installation_id: 987,
        cached_token: "stale-token",
        cached_token_expires_at: 4.minutes.from_now
      )

      expect(installation.fresh_token).to eq("fresh-token")
      expect(installation.reload.cached_token).to eq("fresh-token")
      expect(installation.cached_token_expires_at).to be > 50.minutes.from_now
    end

    it "allows concurrent refreshes; latest write wins" do
      stub_request(:post, "https://api.github.com/app/installations/987/access_tokens")
        .with(headers: { "Authorization" => "Bearer app-jwt" })
        .to_return(status: 201, headers: { "Content-Type" => "application/json" },
                   body: { token: "fresh-one", expires_at: 1.hour.from_now.iso8601 }.to_json)
        .then
        .to_return(status: 201, headers: { "Content-Type" => "application/json" },
                   body: { token: "fresh-two", expires_at: 1.hour.from_now.iso8601 }.to_json)
      installation = Factories.installation(
        user: user,
        github_installation_id: 987,
        cached_token: "stale-token",
        cached_token_expires_at: 1.minute.ago
      )
      first = Installation.find(installation.id)
      second = Installation.find(installation.id)

      expect(first.fresh_token).to eq("fresh-one")
      expect(second.fresh_token).to eq("fresh-two")
      expect(installation.reload.cached_token).to eq("fresh-two")
    end
  end

  describe "installation-auth API fallback" do
    before do
      AppSetting.current.update!(github_app_id: 123, github_app_private_key_pem: "stub-pem")
      allow(GithubAppClient).to receive(:app_jwt).and_return("app-jwt")
    end

    def stub_installation_token(token:, expires_at: 1.hour.from_now)
      stub_request(:post, "https://api.github.com/app/installations/987/access_tokens")
        .with(headers: { "Authorization" => "Bearer app-jwt" })
        .to_return(status: 201, headers: { "Content-Type" => "application/json" },
                   body: { token: token, expires_at: expires_at.iso8601 }.to_json)
    end

    it "refreshes a rejected cached installation token and retries once with App auth" do
      installation = Factories.installation(
        user: user,
        github_installation_id: 987,
        cached_token: "install-token",
        cached_token_expires_at: 1.hour.from_now
      )
      repository.update!(installation: installation)
      stub_request(:get, "https://api.github.com/repos/acme/widgets/issues/42")
        .with(headers: { "Authorization" => "token install-token" })
        .to_return(status: 401, headers: { "Content-Type" => "application/json" },
                   body: { message: "Bad credentials" }.to_json)
      stub_installation_token(token: "fresh-token")
      fresh_stub = stub_request(:get, "https://api.github.com/repos/acme/widgets/issues/42")
        .with(headers: { "Authorization" => "token fresh-token" })
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: { number: 42, title: "Fresh App" }.to_json)

      issue = GithubClient.for(repository: repository, user: user).fetch_issue(repository.slug, 42)

      expect(issue.title).to eq("Fresh App")
      expect(fresh_stub).to have_been_requested
      expect(installation.reload.cached_token).to eq("fresh-token")
      expect(GithubAuthFallbackDiagnostic.count).to eq(0)
    end

    it "falls back to PAT with diagnostics when the refreshed installation token still cannot access the repo" do
      installation = Factories.installation(
        user: user,
        github_installation_id: 987,
        cached_token: "install-token",
        cached_token_expires_at: 1.hour.from_now
      )
      repository.update!(installation: installation)
      run = Factories.job(repository: repository, issue_number: 77).initial_run
      Thread.current[:syrus_current_run] = run
      stub_request(:get, "https://api.github.com/repos/acme/widgets/issues/42")
        .with(headers: { "Authorization" => "token install-token" })
        .to_return(status: 401, headers: { "Content-Type" => "application/json" },
                   body: { message: "Bad credentials" }.to_json)
      stub_installation_token(token: "fresh-token")
      stub_request(:get, "https://api.github.com/repos/acme/widgets/issues/42")
        .with(headers: { "Authorization" => "token fresh-token" })
        .to_return(status: 404, headers: { "Content-Type" => "application/json" },
                   body: { message: "Not Found" }.to_json)
      pat_stub = stub_request(:get, "https://api.github.com/repos/acme/widgets/issues/42")
        .with(headers: { "Authorization" => "token ghp_test_token" })
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: { number: 42, title: "PAT fallback" }.to_json)

      issue = GithubClient.for(repository: repository, user: user).fetch_issue(repository.slug, 42)

      expect(issue.title).to eq("PAT fallback")
      expect(pat_stub).to have_been_requested
      expect(installation.reload.removed_at).to be_nil
      diagnostic = GithubAuthFallbackDiagnostic.last
      expect(diagnostic).to have_attributes(
        repository_id: repository.id,
        installation_id: installation.id,
        github_installation_id: 987,
        operation_type: "api",
        error_class: "Octokit::NotFound",
        error_status: 404,
        refresh_attempted: true,
        refresh_succeeded: true,
        run_id: run.id
      )
      expect(run.job_logs.last).to have_attributes(kind: "github_auth_fallback")
    ensure
      Thread.current[:syrus_current_run] = nil
    end

    it "falls back to PAT when initial token minting fails" do
      installation = Factories.installation(user: user, github_installation_id: 987)
      repository.update!(installation: installation)
      stub_request(:post, "https://api.github.com/app/installations/987/access_tokens")
        .to_return(status: 404, headers: { "Content-Type" => "application/json" },
                   body: { message: "Not Found" }.to_json)
      pat_stub = stub_request(:get, "https://api.github.com/repos/acme/widgets/issues/42")
        .with(headers: { "Authorization" => "token ghp_test_token" })
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: { number: 42, title: "Fallback" }.to_json)

      issue = GithubClient.for(repository: repository, user: user).fetch_issue(repository.slug, 42)

      expect(issue.number).to eq(42)
      expect(pat_stub).to have_been_requested
      expect(installation.reload.removed_at).to be_nil
      expect(GithubAuthFallbackDiagnostic.last).to have_attributes(
        repository_id: repository.id,
        installation_id: installation.id,
        operation_type: "api_token_mint",
        error_class: "Octokit::NotFound",
        error_status: 404,
        refresh_attempted: true,
        refresh_succeeded: false
      )
    end
  end

  describe "#issues_with_label", :vcr do
    it "lists labelled issues for a repo", vcr: { cassette_name: "poll_repository_job/lists_issues" } do
      issues = GithubClient.for(repository: repository, user: user).issues_with_label("acme/widgets", "syrus")
      numbers = issues.map(&:number)
      expect(numbers).to include(42, 43, 44, 45, 46)
    end
  end

  describe "#create_pull_request", :vcr do
    it "opens a PR through Octokit and returns the new resource",
       vcr: { cassette_name: "github_client/create_pull_request" } do
      pr = GithubClient.for(repository: repository, user: user).create_pull_request(
        "acme/widgets",
        base: "main",
        head: "syrus/issue-42-1",
        title: "hello",
        body: "there"
      )
      expect(pr.number).to eq(7)
      expect(pr.html_url).to eq("https://github.com/acme/widgets/pull/7")
    end
  end

  describe "#compare_files" do
    let(:client) { GithubClient.for(repository: repository, user: user) }

    it "extracts changed file metadata and patches from the compare API" do
      stub = stub_request(:get, "https://api.github.com/repos/acme/widgets/compare/main...syrus/issue-42")
        .with(query: hash_including("per_page" => "100"))
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            files: [
              {
                filename: "app/models/user.rb",
                status: "modified",
                additions: 4,
                deletions: 1,
                patch: "@@ -1 +1 @@\n-old\n+new"
              },
              {
                filename: "public/logo.png",
                status: "added",
                additions: 0,
                deletions: 0
              }
            ]
          }.to_json
        )

      result = client.compare_files("acme/widgets", "main", "syrus/issue-42")

      expect(result).to eq(
        files: [
          { path: "app/models/user.rb", status: "modified", additions: 4, deletions: 1, patch: "@@ -1 +1 @@\n-old\n+new" },
          { path: "public/logo.png", status: "added", additions: 0, deletions: 0, patch: nil }
        ],
        truncated: false
      )
      expect(stub).to have_been_requested
    end
  end

  describe "#commit_tree_sha" do
    let(:client) { GithubClient.for(repository: repository, user: user) }

    it "returns the tree SHA for a commit ref" do
      stub = stub_request(:get, "https://api.github.com/repos/acme/widgets/commits/syrus/reconcile")
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            sha: "commit-sha",
            commit: {
              tree: { sha: "tree-sha" }
            }
          }.to_json
        )

      expect(client.commit_tree_sha("acme/widgets", "syrus/reconcile")).to eq("tree-sha")
      expect(stub).to have_been_requested
    end
  end

  describe "#list_tags" do
    let(:client) { GithubClient.for(repository: repository, user: user) }

    it "returns tag names and commit SHAs" do
      stub = stub_request(:get, "https://api.github.com/repos/acme/widgets/tags")
        .with(query: hash_including("per_page" => "100"))
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [
            { name: "staging", commit: { sha: "stage-sha" } },
            { name: "deploy-prod-20260730", commit: { sha: "prod-sha" } }
          ].to_json
        )

      expect(client.list_tags("acme/widgets")).to eq([
        { name: "staging", sha: "stage-sha" },
        { name: "deploy-prod-20260730", sha: "prod-sha" }
      ])
      expect(stub).to have_been_requested
    end

    it "filters by glob or plain prefix pattern" do
      stub_request(:get, "https://api.github.com/repos/acme/widgets/tags")
        .with(query: hash_including("per_page" => "100"))
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: [
            { name: "deploy-prod-20260730", commit: { sha: "prod-sha" } },
            { name: "deploy-canary-20260730", commit: { sha: "canary-sha" } },
            { name: "release", commit: { sha: "release-sha" } }
          ].to_json
        )

      expect(client.list_tags("acme/widgets", pattern: "deploy-prod-*")).to eq([
        { name: "deploy-prod-20260730", sha: "prod-sha" }
      ])
      expect(client.list_tags("acme/widgets", pattern: "deploy-")).to eq([
        { name: "deploy-prod-20260730", sha: "prod-sha" },
        { name: "deploy-canary-20260730", sha: "canary-sha" }
      ])
    end
  end

  describe "#compare_commits" do
    let(:client) { GithubClient.for(repository: repository, user: user) }

    it "includes GitHub's compare status while preserving commit metadata" do
      stub = stub_request(:get, "https://api.github.com/repos/acme/widgets/compare/base-sha...staging")
        .with(query: hash_including("per_page" => "100"))
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            status: "ahead",
            merge_base_commit: { sha: "base-sha" },
            commits: [
              {
                sha: "commitsha123",
                commit: {
                  message: "Deploy app\n\nBody",
                  committer: { date: "2026-07-30T18:00:00Z" }
                }
              }
            ]
          }.to_json
        )

      result = client.compare_commits("acme/widgets", "base-sha", "staging")

      expect(result[:status]).to eq("ahead")
      expect(result[:merge_base_sha]).to eq("base-sha")
      expect(result[:commits].first).to include(
        sha: "commitsha123",
        short_sha: "commits",
        message: "Deploy app"
      )
      expect(stub).to have_been_requested
    end
  end

  describe "#merge_pull_request" do
    let(:client) { GithubClient.for(repository: repository, user: user) }

    it "sends a string commit_message instead of nil" do
      stub = stub_request(:put, "https://api.github.com/repos/acme/widgets/pulls/7/merge")
        .with(body: {
          "commit_message" => "",
          "commit_title" => "Merge acme/widgets#7 via Syrus",
          "merge_method" => "rebase"
        })
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: { merged: true }.to_json)

      result = client.merge_pull_request(
        "acme/widgets",
        7,
        commit_title: "Merge acme/widgets#7 via Syrus",
        merge_method: "rebase"
      )

      expect(result.merged).to be true
      expect(stub).to have_been_requested
    end
  end

  describe "#update_pull_request_base" do
    let(:client) { GithubClient.for(repository: repository, user: user) }

    it "retargets the PR base branch" do
      stub = stub_request(:patch, "https://api.github.com/repos/acme/widgets/pulls/7")
        .with(body: { "base" => "main" })
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: { number: 7, base: { ref: "main" } }.to_json)

      result = client.update_pull_request_base("acme/widgets", 7, base: "main")

      expect(result.number).to eq(7)
      expect(stub).to have_been_requested
    end
  end

  describe "#fetch_issue", :vcr do
    it "returns the issue title + body for prompt construction",
       vcr: { cassette_name: "github_client/fetch_issue" } do
      issue = GithubClient.for(repository: repository, user: user).fetch_issue("acme/widgets", 42)
      expect(issue.number).to eq(42)
      expect(issue.title).to eq("Add greeting helper")
      expect(issue.body).to match(/greeting helper/)
    end
  end

  describe "#add_issue_comment" do
    let(:client) { GithubClient.for(repository: repository, user: user) }

    it "prepends on-behalf-of attribution when a user triggered the comment" do
      user.update!(github_handle: "ada")
      stub = stub_request(:post, "https://api.github.com/repos/acme/widgets/issues/42/comments")
        .with(body: { body: "Syrus on behalf of @ada\n\nLooks good." }.to_json)
        .to_return(status: 201, headers: { "Content-Type" => "application/json" },
                   body: { id: 1, body: "ok" }.to_json)

      client.add_issue_comment("acme/widgets", 42, "Looks good.", on_behalf_of: user)

      expect(stub).to have_been_requested
    end

    it "does not add attribution for autonomous comments" do
      stub = stub_request(:post, "https://api.github.com/repos/acme/widgets/issues/42/comments")
        .with(body: { body: "Lifecycle update." }.to_json)
        .to_return(status: 201, headers: { "Content-Type" => "application/json" },
                   body: { id: 1, body: "ok" }.to_json)

      client.add_issue_comment("acme/widgets", 42, "Lifecycle update.")

      expect(stub).to have_been_requested
    end
  end

  describe "#linked_open_pr_for_issue" do
    let(:client) { GithubClient.for(repository: repository, user: user) }

    def stub_graphql(response_body)
      stub_request(:post, "https://api.github.com/graphql")
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: response_body.to_json)
    end

    it "returns {number, url} for the first OPEN linked PR" do
      stub_graphql(data: { repository: { issue: { closedByPullRequestsReferences: { nodes: [
        { number: 7, url: "https://github.com/acme/widgets/pull/7", state: "OPEN" }
      ] } } } })

      result = client.linked_open_pr_for_issue("acme/widgets", 42)
      expect(result).to eq(number: 7, url: "https://github.com/acme/widgets/pull/7")
    end

    it "returns nil when there are no linked PRs" do
      stub_graphql(data: { repository: { issue: { closedByPullRequestsReferences: { nodes: [] } } } })
      expect(client.linked_open_pr_for_issue("acme/widgets", 42)).to be_nil
    end

    it "returns nil when the issue path resolves to nil (e.g. issue deleted between calls)" do
      stub_graphql(data: { repository: { issue: nil } })
      expect(client.linked_open_pr_for_issue("acme/widgets", 42)).to be_nil
    end

    it "skips non-OPEN states defensively (in case the API returns one despite includeClosedPrs:false)" do
      stub_graphql(data: { repository: { issue: { closedByPullRequestsReferences: { nodes: [
        { number: 5, url: "https://github.com/acme/widgets/pull/5", state: "CLOSED" }
      ] } } } })

      expect(client.linked_open_pr_for_issue("acme/widgets", 42)).to be_nil
    end

    it "sends the right GraphQL query (variables include owner/name/number)" do
      stub = stub_request(:post, "https://api.github.com/graphql")
        .with(body: hash_including("variables" => { "owner" => "acme", "name" => "widgets", "number" => 42 }))
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: { data: { repository: { issue: { closedByPullRequestsReferences: { nodes: [] } } } } }.to_json)

      client.linked_open_pr_for_issue("acme/widgets", 42)
      expect(stub).to have_been_requested
    end
  end

  describe "#accessible_owners" do
    let(:client) { GithubClient.for_user(user) }

    before do
      stub_request(:get, "https://api.github.com/user")
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: { login: "john" }.to_json)
      stub_request(:get, "https://api.github.com/user/orgs")
        .with(query: hash_including({}))
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: [ { login: "org-b" }, { login: "org-a" } ].to_json)
    end

    it "returns the authenticated user's login and sorted org logins" do
      result = client.accessible_owners
      expect(result[:user]).to eq("john")
      expect(result[:orgs]).to eq(%w[org-a org-b])
    end
  end

  describe "#create_issue" do
    let(:client) { GithubClient.for_user(user) }

    it "creates an issue with labels" do
      stub = stub_request(:post, "https://api.github.com/repos/acme/widgets/issues")
        .with(body: hash_including("title" => "New work", "body" => "Do it.", "labels" => %w[bug syrus]))
        .to_return(status: 201, headers: { "Content-Type" => "application/json" },
                   body: { number: 77, title: "New work" }.to_json)

      issue = client.create_issue("acme/widgets", title: "New work", body: "Do it.", labels: %w[bug syrus])

      expect(issue.number).to eq(77)
      expect(stub).to have_been_requested
    end
  end

  describe "#owner_repos" do
    let(:client) { GithubClient.for_user(user) }

    it "fetches the authenticated user's own repos when owner_type is 'user'" do
      stub_request(:get, "https://api.github.com/user/repos")
        .with(query: hash_including("type" => "owner"))
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: [ { name: "repo-b" }, { name: "repo-a" } ].to_json)

      result = client.owner_repos("john", owner_type: "user")
      expect(result).to eq([
        { name: "repo-a", github_repository_id: nil, github_owner_id: nil },
        { name: "repo-b", github_repository_id: nil, github_owner_id: nil }
      ])
    end

    it "fetches org repos when owner_type is 'org'" do
      stub_request(:get, "https://api.github.com/orgs/my-org/repos")
        .with(query: hash_including({}))
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: [ { name: "z-repo" }, { name: "a-repo" } ].to_json)

      result = client.owner_repos("my-org", owner_type: "org")
      expect(result).to eq([
        { name: "a-repo", github_repository_id: nil, github_owner_id: nil },
        { name: "z-repo", github_repository_id: nil, github_owner_id: nil }
      ])
    end
  end

  describe "rate limit tracking" do
    let(:client) { GithubClient.for_user(user) }
    let(:reset_epoch) { 1_714_944_000 }
    let(:rate_limit_headers) do
      {
        "x-ratelimit-remaining" => "4221",
        "x-ratelimit-limit"     => "5000",
        "x-ratelimit-reset"     => reset_epoch.to_s,
        "x-ratelimit-resource"  => "core"
      }
    end

    def stub_user_endpoint(status: 200, extra_headers: {})
      stub_request(:get, "https://api.github.com/user")
        .to_return(
          status: status,
          headers: { "Content-Type" => "application/json" }.merge(rate_limit_headers).merge(extra_headers),
          body: status == 200 ? { login: "john" }.to_json : { message: "API rate limit exceeded" }.to_json
        )
    end

    def stub_orgs_endpoint
      stub_request(:get, "https://api.github.com/user/orgs")
        .with(query: hash_including({}))
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" }.merge(rate_limit_headers),
          body: [].to_json
        )
    end

    it "persists rate limit columns after a successful API call" do
      stub_user_endpoint
      stub_orgs_endpoint

      client.accessible_owners

      user.reload
      expect(user.gh_rate_limit_remaining).to eq(4221)
      expect(user.gh_rate_limit_limit).to eq(5000)
      expect(user.gh_rate_limit_resource).to eq("core")
      expect(user.gh_rate_limit_reset_at).to be_within(1.second).of(Time.at(reset_epoch))
      expect(user.gh_rate_limit_observed_at).to be_within(5.seconds).of(Time.current)
    end

    it "persists rate limit columns and writes a kind=rate_limited JobLog on TooManyRequests" do
      run = Factories.run
      Thread.current[:syrus_current_run] = run

      stub_user_endpoint(status: 403, extra_headers: { "x-ratelimit-remaining" => "0" })

      expect { client.accessible_owners }.to raise_error(Octokit::TooManyRequests)

      user.reload
      expect(user.gh_rate_limit_remaining).to eq(0)

      log = run.reload.job_logs.last
      expect(log).to be_present
      expect(log.kind).to eq("rate_limited")
      expect(log.chunk).to include("rate-limited")
      expect(log.chunk).to include("core")
    ensure
      Thread.current[:syrus_current_run] = nil
    end

    it "persists rate limit columns but skips JobLog when no run context is set" do
      Thread.current[:syrus_current_run] = nil
      run = Factories.run

      stub_user_endpoint(status: 403, extra_headers: { "x-ratelimit-remaining" => "0" })

      expect { client.accessible_owners }.to raise_error(Octokit::TooManyRequests)

      user.reload
      expect(user.gh_rate_limit_remaining).to eq(0)
      expect(JobLog.where(kind: "rate_limited").count).to eq(0)
    end

    # Regression: every GH API call used to UPDATE the user row, racing
    # background pollers against the request-thread credentials update
    # and tripping innodb_lock_wait_timeout in prod. The persister now
    # coalesces — skip the write when the remaining count hasn't moved
    # and we updated recently. Calling the method directly avoids
    # faraday-http-cache returning the first response on retry.
    describe "#persist_rate_limit_headers! coalescing" do
      let(:headers_with) do
        ->(remaining) do
          {
            "x-ratelimit-remaining" => remaining.to_s,
            "x-ratelimit-limit" => "5000",
            "x-ratelimit-reset" => reset_epoch.to_s,
            "x-ratelimit-resource" => "core"
          }
        end
      end

      it "skips the row write when the remaining count is unchanged and observed_at is recent" do
        client.send(:persist_rate_limit_headers!, headers_with.call(4221))
        user.reload
        first_observed_at = user.gh_rate_limit_observed_at

        travel 1.second do
          client.send(:persist_rate_limit_headers!, headers_with.call(4221))
        end

        expect(user.reload.gh_rate_limit_observed_at).to eq(first_observed_at)
      end

      it "writes again when the remaining count moves even within the coalesce window" do
        client.send(:persist_rate_limit_headers!, headers_with.call(4221))

        travel 1.second do
          client.send(:persist_rate_limit_headers!, headers_with.call(4200))
        end

        expect(user.reload.gh_rate_limit_remaining).to eq(4200)
      end

      it "writes again after the coalesce window even when remaining is unchanged" do
        client.send(:persist_rate_limit_headers!, headers_with.call(4221))
        user.reload
        first_observed_at = user.gh_rate_limit_observed_at

        travel (described_class::RATE_LIMIT_PERSIST_COALESCE + 1.second) do
          client.send(:persist_rate_limit_headers!, headers_with.call(4221))
        end

        expect(user.reload.gh_rate_limit_observed_at).to be > first_observed_at
      end
    end
  end

  describe "#delete_branch" do
    let(:client) { GithubClient.for_user(user) }
    let(:delete_url) { "https://api.github.com/repos/acme/widgets/git/refs/heads/syrus/issue-42-1" }

    it "calls the GitHub delete ref API for the branch" do
      stub = stub_request(:delete, delete_url).to_return(status: 204, body: "")
      expect(client.delete_branch("acme/widgets", "syrus/issue-42-1")).to be(true)
      expect(stub).to have_been_requested
    end

    it "suppresses 422 UnprocessableEntity and logs a warning" do
      stub_request(:delete, delete_url).to_return(
        status: 422,
        headers: { "Content-Type" => "application/json" },
        body: { message: "Reference cannot be deleted" }.to_json
      )
      expect(Rails.logger).to receive(:warn).with(/could not delete/)
      expect(client.delete_branch("acme/widgets", "syrus/issue-42-1")).to be(false)
    end

    it "suppresses 404 NotFound and logs a warning" do
      stub_request(:delete, delete_url).to_return(
        status: 404,
        headers: { "Content-Type" => "application/json" },
        body: { message: "Not Found" }.to_json
      )
      allow(Rails.logger).to receive(:warn)
      expect(client.delete_branch("acme/widgets", "syrus/issue-42-1")).to be(false)
      expect(Rails.logger).to have_received(:warn).with(/could not delete/)
    end

    it "retries transient GitHub server errors and succeeds when a later delete works" do
      stub = stub_request(:delete, delete_url)
             .to_return(
               { status: 504, headers: { "Content-Type" => "application/json" }, body: { message: "Gateway Timeout" }.to_json },
               { status: 204, body: "" }
             )
      allow(Rails.logger).to receive(:warn)

      expect(client.delete_branch("acme/widgets", "syrus/issue-42-1")).to be(true)
      expect(stub).to have_been_requested.twice
      expect(Rails.logger).to have_received(:warn).with(/transient failure deleting/)
    end

    it "suppresses transient GitHub server errors after bounded retries" do
      stub = stub_request(:delete, delete_url).to_return(
        status: 504,
        headers: { "Content-Type" => "application/json" },
        body: { message: "Gateway Timeout" }.to_json
      )
      allow(Rails.logger).to receive(:warn)

      expect(client.delete_branch("acme/widgets", "syrus/issue-42-1")).to be(false)
      expect(stub).to have_been_requested.times(3)
      expect(Rails.logger).to have_received(:warn).with(/after transient GitHub failures/)
    end

    it "suppresses TooManyRequests and logs a warning" do
      stub_request(:delete, delete_url).to_return(
        status: 403,
        headers: { "Content-Type" => "application/json", "x-ratelimit-remaining" => "0" },
        body: { message: "API rate limit exceeded" }.to_json
      )
      expect(Rails.logger).to receive(:warn).with(/rate-limited deleting/)
      expect(client.delete_branch("acme/widgets", "syrus/issue-42-1")).to be(false)
    end
  end

  describe "#upload_issue_asset" do
    let(:client) { GithubClient.for_user(user) }
    let(:octokit) { client.instance_variable_get(:@client) }
    let(:fake_ref) { double("ref", object: double("object", sha: "abc123sha")) }
    let(:fake_repo) { double("repo", default_branch: "main") }

    def stub_branch_exists
      allow(octokit).to receive(:ref)
        .with("acme/widgets", "heads/bug-report-media")
        .and_return(fake_ref)
    end

    def stub_branch_missing
      allow(octokit).to receive(:ref)
        .with("acme/widgets", "heads/bug-report-media")
        .and_raise(Octokit::NotFound)
      allow(octokit).to receive(:repository)
        .with("acme/widgets")
        .and_return(fake_repo)
      allow(octokit).to receive(:ref)
        .with("acme/widgets", "heads/main")
        .and_return(fake_ref)
      allow(octokit).to receive(:create_ref)
        .with("acme/widgets", "refs/heads/bug-report-media", "abc123sha")
        .and_return(double("created_ref"))
    end

    def stub_create_contents
      allow(octokit).to receive(:create_contents)
        .with("acme/widgets", anything, anything, anything, branch: "bug-report-media")
        .and_return(double("contents_response"))
    end

    it "returns a raw.githubusercontent.com URL when the branch already exists" do
      stub_branch_exists
      stub_create_contents

      result = client.upload_issue_asset(
        "acme/widgets",
        io: StringIO.new("\x89PNG\r\n\x1A\nfakedata"),
        content_type: "image/png",
        filename: "screenshot.png"
      )

      expect(result).to match(%r{\Ahttps://raw\.githubusercontent\.com/acme/widgets/bug-report-media/bug-report-attachments/[0-9a-f-]+/screenshot\.png\z})
    end

    it "passes raw binary content to create_contents without base64 encoding" do
      stub_branch_exists
      binary_data = "\x89PNG\r\n\x1A\nfakedata"
      allow(octokit).to receive(:create_contents)
        .with("acme/widgets", anything, anything, binary_data.b, branch: "bug-report-media")
        .and_return(double("contents_response"))

      client.upload_issue_asset(
        "acme/widgets",
        io: StringIO.new(binary_data),
        content_type: "image/png",
        filename: "screenshot.png"
      )

      expect(octokit).to have_received(:create_contents)
        .with("acme/widgets", anything, anything, binary_data.b, branch: "bug-report-media")
    end

    it "creates the branch when it does not exist, then writes the file" do
      stub_branch_missing
      stub_create_contents

      result = client.upload_issue_asset(
        "acme/widgets",
        io: StringIO.new("data"),
        content_type: "image/pdf",
        filename: "report.pdf"
      )

      expect(octokit).to have_received(:create_ref)
        .with("acme/widgets", "refs/heads/bug-report-media", "abc123sha")
      expect(result).to match(%r{\Ahttps://raw\.githubusercontent\.com/acme/widgets/bug-report-media/bug-report-attachments/[0-9a-f-]+/report\.pdf\z})
    end

    it "returns nil and logs a warning when create_contents raises" do
      stub_branch_exists
      allow(octokit).to receive(:create_contents).and_raise(Octokit::Error)

      expect(Rails.logger).to receive(:warn).with(/\[GithubClient\] upload_issue_asset acme\/widgets\/shot\.png failed/)

      result = client.upload_issue_asset(
        "acme/widgets",
        io: StringIO.new("data"),
        content_type: "image/png",
        filename: "shot.png"
      )

      expect(result).to be_nil
    end

    it "rewinds the io before reading to handle already-read streams" do
      io = StringIO.new("already read content")
      io.read
      stub_branch_exists
      stub_create_contents

      result = client.upload_issue_asset(
        "acme/widgets",
        io: io,
        content_type: "image/png",
        filename: "shot.png"
      )

      expect(result).to match(%r{\Ahttps://raw\.githubusercontent\.com/acme/widgets/bug-report-media/})
    end
  end

  describe "#merge_upstream" do
    it "POSTs to the merge-upstream endpoint with the branch" do
      stub = stub_request(:post, "https://api.github.com/repos/acme/widgets/merge-upstream")
        .with(body: { branch: "main" })
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: { merge_type: "fast-forward", base_branch: "main", message: "ok" }.to_json)

      result = GithubClient.for(repository: repository, user: user).merge_upstream("acme/widgets", "main")

      expect(stub).to have_been_requested
      expect(result.merge_type).to eq("fast-forward")
    end

    it "propagates a conflict (409) as Octokit::Conflict" do
      stub_request(:post, "https://api.github.com/repos/acme/widgets/merge-upstream")
        .to_return(status: 409, headers: { "Content-Type" => "application/json" },
                   body: { message: "merge conflict" }.to_json)

      expect {
        GithubClient.for(repository: repository, user: user).merge_upstream("acme/widgets", "main")
      }.to raise_error(Octokit::Conflict)
    end
  end
end
