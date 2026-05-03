require "rails_helper"

RSpec.describe GithubClient do
  let(:user) { Factories.user(github_token: "ghp_test_token") }

  it "raises when the user has no github_token" do
    bare = Factories.user
    expect { GithubClient.new(bare) }.to raise_error(ArgumentError)
  end

  describe "#issues_with_label", :vcr do
    it "lists labelled issues for a repo", vcr: { cassette_name: "poll_repository_job/lists_issues" } do
      issues = GithubClient.for(user).issues_with_label("acme/widgets", "syrus")
      numbers = issues.map(&:number)
      expect(numbers).to include(42, 43, 44, 45, 46)
    end
  end

  describe "#create_pull_request", :vcr do
    it "opens a PR through Octokit and returns the new resource",
       vcr: { cassette_name: "github_client/create_pull_request" } do
      pr = GithubClient.for(user).create_pull_request(
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

  describe "#fetch_issue", :vcr do
    it "returns the issue title + body for prompt construction",
       vcr: { cassette_name: "github_client/fetch_issue" } do
      issue = GithubClient.for(user).fetch_issue("acme/widgets", 42)
      expect(issue.number).to eq(42)
      expect(issue.title).to eq("Add greeting helper")
      expect(issue.body).to match(/greeting helper/)
    end
  end

  describe "#linked_open_pr_for_issue" do
    let(:client) { GithubClient.for(user) }

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
    let(:client) { GithubClient.for(user) }

    before do
      stub_request(:get, "https://api.github.com/user")
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: { login: "john" }.to_json)
      stub_request(:get, "https://api.github.com/user/orgs")
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: [ { login: "org-b" }, { login: "org-a" } ].to_json)
    end

    it "returns the authenticated user's login and sorted org logins" do
      result = client.accessible_owners
      expect(result[:user]).to eq("john")
      expect(result[:orgs]).to eq(%w[org-a org-b])
    end
  end

  describe "#owner_repos" do
    let(:client) { GithubClient.for(user) }

    it "fetches the authenticated user's own repos when owner_type is 'user'" do
      stub_request(:get, "https://api.github.com/user/repos")
        .with(query: hash_including("type" => "owner"))
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: [ { name: "repo-b" }, { name: "repo-a" } ].to_json)

      result = client.owner_repos("john", owner_type: "user")
      expect(result).to eq(%w[repo-a repo-b])
    end

    it "fetches org repos when owner_type is 'org'" do
      stub_request(:get, "https://api.github.com/orgs/my-org/repos")
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: [ { name: "z-repo" }, { name: "a-repo" } ].to_json)

      result = client.owner_repos("my-org", owner_type: "org")
      expect(result).to eq(%w[a-repo z-repo])
    end
  end
end
