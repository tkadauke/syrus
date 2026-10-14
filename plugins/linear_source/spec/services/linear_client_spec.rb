require "rails_helper"

RSpec.describe LinearClient do
  subject(:client) { described_class.new(api_key: "lin_api_test") }

  def issue_page(nodes:, has_next_page:, end_cursor: nil)
    {
      "data" => {
        "issues" => {
          "nodes" => nodes,
          "pageInfo" => {
            "hasNextPage" => has_next_page,
            "endCursor" => end_cursor
          }
        }
      }
    }
  end

  describe "#issues" do
    it "fetches every page of issues" do
      first_issue = { "id" => "issue-1" }
      second_issue = { "id" => "issue-2" }

      expect(client).to receive(:execute).ordered.with(
        described_class::ISSUES_QUERY,
        variables: { teamId: "team-1", first: 100, after: nil }
      ).and_return(issue_page(nodes: [ first_issue ], has_next_page: true, end_cursor: "cursor-1"))
      expect(client).to receive(:execute).ordered.with(
        described_class::ISSUES_QUERY,
        variables: { teamId: "team-1", first: 100, after: "cursor-1" }
      ).and_return(issue_page(nodes: [ second_issue ], has_next_page: false))

      expect(client.issues(team_id: "team-1")).to eq([ first_issue, second_issue ])
    end

    it "paginates the label-filtered query" do
      expect(client).to receive(:execute).ordered.with(
        described_class::ISSUES_WITH_LABEL_QUERY,
        variables: { teamId: "team-1", first: 100, labelName: "syrus", after: nil }
      ).and_return(issue_page(nodes: [], has_next_page: true, end_cursor: "cursor-1"))
      expect(client).to receive(:execute).ordered.with(
        described_class::ISSUES_WITH_LABEL_QUERY,
        variables: { teamId: "team-1", first: 100, labelName: "syrus", after: "cursor-1" }
      ).and_return(issue_page(nodes: [], has_next_page: false))

      expect(client.issues(team_id: "team-1", label_name: "syrus")).to eq([])
    end

    it "returns nil when a later page is rate-limited" do
      allow(client).to receive(:execute).and_return(
        issue_page(nodes: [ { "id" => "issue-1" } ], has_next_page: true, end_cursor: "cursor-1"),
        nil
      )

      expect(client.issues(team_id: "team-1")).to be_nil
    end

    it "raises when Linear reports another page without a cursor" do
      allow(client).to receive(:execute).and_return(issue_page(nodes: [], has_next_page: true))

      expect { client.issues(team_id: "team-1") }.to raise_error(/without an end cursor/)
    end

    it "stops pagination at the maximum page count" do
      stub_const("LinearClient::MAX_ISSUE_PAGES", 2)
      allow(client).to receive(:execute).and_return(
        issue_page(nodes: [], has_next_page: true, end_cursor: "cursor-1"),
        issue_page(nodes: [], has_next_page: true, end_cursor: "cursor-2")
      )

      expect { client.issues(team_id: "team-1") }.to raise_error(/exceeded 2 pages/)
    end
  end
end
