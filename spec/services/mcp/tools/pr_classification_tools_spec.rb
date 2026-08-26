require "rails_helper"
require "ostruct"

RSpec.describe "Mcp::Tools PR classification tools" do
  let(:user) { Factories.user(github_token: "ghp_test_token") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets", external_pr_ingestion_enabled: true) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

  def chat_context = { chat_session: chat_session }

  def payload(response)
    JSON.parse(response.content.first[:text], symbolize_names: true)
  end

  def pr(number:, head_ref: "feature/cool-thing", head_repo: "acme/widgets", base_repo: "acme/widgets", author: "contributor", title: "Some feature", body: nil)
    OpenStruct.new(
      number: number,
      title: title,
      body: body,
      head: OpenStruct.new(ref: head_ref, repo: OpenStruct.new(full_name: head_repo)),
      base: OpenStruct.new(ref: "main", repo: OpenStruct.new(full_name: base_repo)),
      user: OpenStruct.new(login: author)
    )
  end

  describe Mcp::Tools::ClassifyPullRequestTool do
    it "classifies a same-repo PR as external_unknown by default" do
      allow_any_instance_of(GithubClient).to receive(:pull_request).with("acme/widgets", 10).and_return(pr(number: 10))

      response = described_class.call(pr_number: 10, server_context: chat_context)

      expect(response).not_to be_error
      body = payload(response)
      expect(body[:classification]).to eq("external_unknown")
      expect(body[:evidence][:fork_pr]).to be(false)
    end

    it "flags a fork PR in the evidence" do
      allow_any_instance_of(GithubClient).to receive(:pull_request).with("acme/widgets", 11).and_return(
        pr(number: 11, head_repo: "someone-else/widgets")
      )

      body = payload(described_class.call(pr_number: 11, server_context: chat_context))
      expect(body[:evidence][:fork_pr]).to be(true)
    end

    it "returns an error when the PR does not exist" do
      allow_any_instance_of(GithubClient).to receive(:pull_request).with("acme/widgets", 999).and_raise(Octokit::NotFound)

      response = described_class.call(pr_number: 999, server_context: chat_context)

      expect(response).to be_error
      expect(response.content.first[:text]).to include("not found")
    end
  end

  describe Mcp::Tools::IngestPullRequestTool do
    it "ingests a new external PR as external_unknown" do
      allow_any_instance_of(GithubClient).to receive(:pull_request).with("acme/widgets", 20).and_return(
        pr(number: 20, title: "Add widget", author: "alice")
      )

      expect {
        described_class.call(pr_number: 20, server_context: chat_context)
      }.to change(Job, :count).by(1)

      job = Job.find_by!(repository: repository, external_pr_number: 20)
      expect(job.kind).to eq("external_pr")
    end

    it "returns the existing job idempotently when already ingested and no override is given" do
      existing = Job.create!(user: user, repository: repository, kind: "external_pr", state: "implemented", external_pr_number: 30)

      response = described_class.call(pr_number: 30, server_context: chat_context)

      expect(response).not_to be_error
      body = payload(response)
      expect(body[:already_ingested]).to be(true)
      expect(body.dig(:job, :id)).to eq(existing.id)
    end

    it "rejects an invalid classification override" do
      response = described_class.call(pr_number: 40, classification: "not_a_kind", server_context: chat_context)

      expect(response).to be_error
      expect(response.content.first[:text]).to include("classification must be one of")
    end

    it "still returns the existing job when a classification override is given for an already-ingested PR" do
      existing = Job.create!(user: user, repository: repository, kind: "external_pr", state: "implemented", external_pr_number: 50)

      response = described_class.call(pr_number: 50, classification: "external_unknown", server_context: chat_context)

      expect(response).not_to be_error
      body = payload(response)
      expect(body[:already_ingested]).to be(true)
      expect(body.dig(:job, :id)).to eq(existing.id)
    end

    it "uses the classification override on first ingestion instead of the automatic heuristic" do
      allow_any_instance_of(GithubClient).to receive(:pull_request).with("acme/widgets", 51).and_return(pr(number: 51))

      response = described_class.call(pr_number: 51, classification: "manual_hotfix", server_context: chat_context)

      expect(response).not_to be_error
      body = payload(response)
      expect(body[:classification]).to eq("manual_hotfix")
      expect(body[:job]).to be_nil
      expect(Job.find_by(repository: repository, external_pr_number: 51)).to be_nil
    end
  end
end
