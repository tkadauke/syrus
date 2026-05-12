require "rails_helper"

RSpec.describe "Repository issues browser", type: :request do
  let(:user)  { Factories.user(github_handle: "ada") }
  let(:other) { Factories.user }
  let(:repo)  { Factories.repository(user: user, owner: "acme", name: "widgets", trigger_label: "syrus") }

  def stub_github_client(double)
    allow(GithubClient).to receive(:for).and_return(double)
  end

  # Sawyer::Resource is a dynamic class — instance_double won't work for its
  # duck-typed attributes. Plain doubles are fine for these view-layer objects.
  def fake_issue(number:, title: "Fix something", state: "open", labels: [], body: nil)
    double(
      "issue",
      number: number,
      title: title,
      state: state,
      html_url: "https://github.com/acme/widgets/issues/#{number}",
      body: body,
      created_at: 1.day.ago,
      user: double("user", login: "alice"),
      labels: labels.map { |name| double("label", name: name, color: "0075ca") },
      pull_request: nil
    )
  end

  context "unauthenticated" do
    it "redirects to sign in" do
      get issues_repository_path(repo)
      expect(response).to redirect_to(new_session_path)
    end
  end

  context "signed in" do
    before { sign_in_as(user) }

    describe "GET /repositories/:id/issues" do
      it "renders open issues from GitHub" do
        issues = [ fake_issue(number: 7, title: "A bug"), fake_issue(number: 3, title: "Another bug") ]
        stub_github_client(instance_double(GithubClient, list_all_issues: issues))

        get issues_repository_path(repo)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("A bug")
        expect(response.body).to include("Another bug")
        expect(response.body).to include("#7")
        expect(response.body).to include("#3")
      end

      it "passes state=closed to GitHub when requested" do
        client = instance_double(GithubClient)
        expect(client).to receive(:list_all_issues).with("acme/widgets", state: "closed").and_return([])
        stub_github_client(client)

        get issues_repository_path(repo, state: "closed")
        expect(response).to have_http_status(:ok)
      end

      it "defaults to state=open" do
        client = instance_double(GithubClient)
        expect(client).to receive(:list_all_issues).with("acme/widgets", state: "open").and_return([])
        stub_github_client(client)

        get issues_repository_path(repo)
        expect(response).to have_http_status(:ok)
      end

      it "rejects unknown state values (falls back to open)" do
        client = instance_double(GithubClient)
        expect(client).to receive(:list_all_issues).with("acme/widgets", state: "open").and_return([])
        stub_github_client(client)

        get issues_repository_path(repo, state: "hacked")
        expect(response).to have_http_status(:ok)
      end

      it "shows a 'Delegated' badge on issues that already have the trigger label" do
        labeled = fake_issue(number: 5, title: "Already delegated", labels: [ "syrus" ])
        stub_github_client(instance_double(GithubClient, list_all_issues: [ labeled ]))

        get issues_repository_path(repo)
        expect(response.body).to include("Delegated")
        expect(response.body).not_to match(/value="Delegate"/)
      end

      it "shows a Delegate button on issues without the trigger label" do
        unlabeled = fake_issue(number: 9, title: "Needs work")
        stub_github_client(instance_double(GithubClient, list_all_issues: [ unlabeled ]))

        get issues_repository_path(repo)
        expect(response.body).to include("Delegate")
      end

      it "shows bulk issue controls" do
        issues = [ fake_issue(number: 9, title: "Needs work") ]
        stub_github_client(instance_double(GithubClient, list_all_issues: issues))

        get issues_repository_path(repo)

        expect(response.body).to include("Close selected")
        expect(response.body).to include("Delegate selected")
        expect(response.body).to include("issue_numbers[]")
      end

      it "shows an empty state message when there are no issues" do
        stub_github_client(instance_double(GithubClient, list_all_issues: []))

        get issues_repository_path(repo)
        expect(response.body).to include("No open issues found")
      end

      it "shows a flash alert when no GitHub token is configured" do
        allow(GithubClient).to receive(:for).and_raise(ArgumentError)

        get issues_repository_path(repo)
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("No GitHub token configured")
      end

      it "returns 404 for another user's repository" do
        foreign = Factories.repository(user: other)
        stub_github_client(instance_double(GithubClient, list_all_issues: []))

        get issues_repository_path(foreign)
        expect(response).to have_http_status(:not_found)
      end
    end

    describe "POST /repositories/:id/comment_issue" do
      it "calls add_issue_comment and redirects with a notice" do
        client = instance_double(GithubClient, add_issue_comment: nil)
        expect(client).to receive(:add_issue_comment).with("acme/widgets", 7, "Looks good to me", on_behalf_of: user)
        stub_github_client(client)

        post comment_issue_repository_path(repo),
             params: { issue_number: 7, comment_body: "Looks good to me", state: "open" }

        expect(response).to redirect_to(issues_repository_path(repo, state: "open"))
        expect(flash[:notice]).to match(/#7/)
      end

      it "rejects blank comment body" do
        stub_github_client(instance_double(GithubClient))

        post comment_issue_repository_path(repo),
             params: { issue_number: 7, comment_body: "   ", state: "open" }

        expect(response).to redirect_to(issues_repository_path(repo, state: "open"))
        expect(flash[:alert]).to match(/blank/)
      end

      it "returns 404 for another user's repository" do
        foreign = Factories.repository(user: other)

        post comment_issue_repository_path(foreign),
             params: { issue_number: 1, comment_body: "hi" }

        expect(response).to have_http_status(:not_found)
      end
    end

    describe "POST /repositories/:id/close_issue" do
      it "calls close_issue and redirects with a notice" do
        client = instance_double(GithubClient)
        expect(client).to receive(:close_issue).with("acme/widgets", 12)
        stub_github_client(client)

        post close_issue_repository_path(repo),
             params: { issue_number: 12, state: "open" }

        expect(response).to redirect_to(issues_repository_path(repo, state: "open"))
        expect(flash[:notice]).to match(/#12/)
      end

      it "redirects with an alert when GitHub raises" do
        client = instance_double(GithubClient)
        allow(client).to receive(:close_issue).and_raise(Octokit::NotFound)
        stub_github_client(client)

        post close_issue_repository_path(repo),
             params: { issue_number: 99, state: "open" }

        expect(response).to redirect_to(issues_repository_path(repo, state: "open"))
        expect(flash[:alert]).to match(/Failed/)
      end

      it "returns 404 for another user's repository" do
        foreign = Factories.repository(user: other)

        post close_issue_repository_path(foreign),
             params: { issue_number: 1 }

        expect(response).to have_http_status(:not_found)
      end
    end

    describe "POST /repositories/:id/delegate_issue" do
      it "adds the trigger label and redirects with a notice" do
        client = instance_double(GithubClient)
        expect(client).to receive(:add_label_to_issue).with("acme/widgets", 4, "syrus")
        stub_github_client(client)

        post delegate_issue_repository_path(repo),
             params: { issue_number: 4, state: "open" }

        expect(response).to redirect_to(issues_repository_path(repo, state: "open"))
        expect(flash[:notice]).to match(/#4.*Syrus/i)
      end

      it "redirects with an alert when GitHub raises" do
        client = instance_double(GithubClient)
        allow(client).to receive(:add_label_to_issue).and_raise(Octokit::UnprocessableEntity)
        stub_github_client(client)

        post delegate_issue_repository_path(repo),
             params: { issue_number: 4, state: "open" }

        expect(response).to redirect_to(issues_repository_path(repo, state: "open"))
        expect(flash[:alert]).to match(/Failed/)
      end

      it "returns 404 for another user's repository" do
        foreign = Factories.repository(user: other)

        post delegate_issue_repository_path(foreign),
             params: { issue_number: 1 }

        expect(response).to have_http_status(:not_found)
      end
    end

    describe "POST /repositories/:id/bulk_issues" do
      it "adds the trigger label to each selected issue" do
        client = instance_double(GithubClient)
        expect(client).to receive(:add_label_to_issue).with("acme/widgets", 4, "syrus")
        expect(client).to receive(:add_label_to_issue).with("acme/widgets", 8, "syrus")
        stub_github_client(client)

        post bulk_issues_repository_path(repo),
             params: { issue_numbers: %w[4 8], bulk_action: "delegate", state: "open" }

        expect(response).to redirect_to(issues_repository_path(repo, state: "open"))
        expect(flash[:notice]).to eq("2 issues delegated to Syrus.")
      end

      it "closes each selected issue" do
        client = instance_double(GithubClient)
        expect(client).to receive(:close_issue).with("acme/widgets", 4)
        expect(client).to receive(:close_issue).with("acme/widgets", 8)
        stub_github_client(client)

        post bulk_issues_repository_path(repo),
             params: { issue_numbers: %w[4 8], bulk_action: "close", state: "open" }

        expect(response).to redirect_to(issues_repository_path(repo, state: "open"))
        expect(flash[:notice]).to eq("2 issues closed.")
      end

      it "deduplicates selected issue numbers" do
        client = instance_double(GithubClient)
        expect(client).to receive(:close_issue).once.with("acme/widgets", 4)
        stub_github_client(client)

        post bulk_issues_repository_path(repo),
             params: { issue_numbers: %w[4 4 not-a-number], bulk_action: "close", state: "open" }

        expect(response).to redirect_to(issues_repository_path(repo, state: "open"))
        expect(flash[:notice]).to eq("1 issue closed.")
      end

      it "redirects with an alert when no issues are selected" do
        stub_github_client(instance_double(GithubClient))

        post bulk_issues_repository_path(repo),
             params: { bulk_action: "delegate", state: "open" }

        expect(response).to redirect_to(issues_repository_path(repo, state: "open"))
        expect(flash[:alert]).to match(/Select/)
      end

      it "redirects with an alert when GitHub raises" do
        client = instance_double(GithubClient)
        allow(client).to receive(:add_label_to_issue).and_raise(Octokit::UnprocessableEntity)
        stub_github_client(client)

        post bulk_issues_repository_path(repo),
             params: { issue_numbers: [ "4" ], bulk_action: "delegate", state: "open" }

        expect(response).to redirect_to(issues_repository_path(repo, state: "open"))
        expect(flash[:alert]).to match(/Failed to delegate issues/)
      end

      it "returns 404 for another user's repository" do
        foreign = Factories.repository(user: other)

        post bulk_issues_repository_path(foreign),
             params: { issue_numbers: [ "1" ], bulk_action: "close" }

        expect(response).to have_http_status(:not_found)
      end
    end
  end
end
