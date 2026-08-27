require "rails_helper"

RSpec.describe GitHistory::RelayClient do
  let(:repository) { Factories.repository }
  let(:client) { described_class.new(repository: repository) }

  def available_url
    "http://127.0.0.1:#{GitHistory::RelayServer::PORT}/repositories/#{repository.id}/available"
  end

  def commits_url
    "http://127.0.0.1:#{GitHistory::RelayServer::PORT}/repositories/#{repository.id}/commits"
  end

  def stub_commits(cursor: nil, limit: 30)
    stub_request(:get, commits_url).with(query: { cursor: cursor, limit: limit }.compact)
  end

  describe "#available?" do
    it "returns true when the relay reports the bare clone is available" do
      stub_request(:get, available_url).to_return(
        status: 200, headers: { "Content-Type" => "application/json" }, body: { available: true }.to_json
      )

      expect(client.available?).to be true
    end

    it "returns false when the relay reports the bare clone is not available" do
      stub_request(:get, available_url).to_return(
        status: 200, headers: { "Content-Type" => "application/json" }, body: { available: false }.to_json
      )

      expect(client.available?).to be false
    end

    it "returns false (does not raise) when the relay is unreachable" do
      stub_request(:get, available_url).to_raise(Errno::ECONNREFUSED)

      expect(client.available?).to be false
    end

    it "returns false (does not raise) when the relay times out" do
      stub_request(:get, available_url).to_timeout

      expect(client.available?).to be false
    end

    it "returns false (does not raise) when the relay returns a non-success status" do
      stub_request(:get, available_url).to_return(status: 500, body: "boom")

      expect(client.available?).to be false
    end
  end

  describe "#fetch" do
    it "returns entries and has_more parsed from the relay" do
      stub_commits(limit: 30).to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          entries: [ { sha: "a" * 40, author_name: "Ada", author_email: "ada@example.com",
                        committer_name: "Ada", committer_email: "ada@example.com",
                        authored_at: "2026-08-01T00:00:00Z", subject: "did a thing" } ],
          has_more: true
        }.to_json
      )

      page = client.fetch(cursor: nil, limit: 30)

      expect(page.has_more).to be true
      expect(page.entries).to contain_exactly(
        a_hash_including(sha: "a" * 40, subject: "did a thing", author_name: "Ada")
      )
    end

    it "forwards the cursor as a query param" do
      stub = stub_commits(cursor: "deadbeef", limit: 10).to_return(
        status: 200, headers: { "Content-Type" => "application/json" }, body: { entries: [], has_more: false }.to_json
      )

      client.fetch(cursor: "deadbeef", limit: 10)

      expect(stub).to have_been_requested
    end

    it "returns an empty page (does not raise) when the relay is unreachable" do
      stub_commits(limit: 30).to_raise(Errno::ECONNREFUSED)

      page = client.fetch(cursor: nil, limit: 30)

      expect(page.entries).to eq([])
      expect(page.has_more).to be false
    end

    it "returns an empty page (does not raise) when the relay returns a non-success status" do
      stub_commits(limit: 30).to_return(status: 500, body: "boom")

      page = client.fetch(cursor: nil, limit: 30)

      expect(page.entries).to eq([])
      expect(page.has_more).to be false
    end
  end
end
