require "rails_helper"
require "ostruct"

RSpec.describe "CI read tools" do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:job) { Factories.job_record(user: user, repository: repository, state: "running", pr_number: 42, branch_name: "syrus/issue-42") }
  let(:workflow) { Workflows::Initial.instantiate(job: job) }
  let(:run) { workflow.first_step.runs.create!(job: job, trigger_kind: workflow.trigger_kind) }
  let(:client) { instance_double(GithubClient) }
  let(:checks) do
    [
      { name: "e2e", status: "completed", conclusion: "failure", summary: "Process completed with exit code 1.",
        html_url: "https://github.com/acme/widgets/actions/runs/9/job/77", actions_job_id: 77 },
      { name: "lint", status: "completed", conclusion: "success", html_url: "https://github.com/acme/widgets/runs/5" },
      { name: "codecov", status: "completed", conclusion: "failure", html_url: "https://codecov.io/x",
        output_text: "coverage dropped by 3%" }
    ]
  end

  before do
    allow(GithubClient).to receive(:for).and_return(client)
    allow(client).to receive(:pull_request).with("acme/widgets", 42).and_return(OpenStruct.new(head: OpenStruct.new(sha: "a" * 40)))
    allow(client).to receive(:ci_checks_for).with("acme/widgets", "a" * 40).and_return(checks)
  end

  def payload(response) = JSON.parse(response.content.first[:text])

  describe Mcp::Tools::ListCiChecksTool do
    it "lists the checks on the Job's pull request head and says which logs are readable" do
      response = described_class.call(server_context: { run: run })

      expect(response).not_to be_error
      body = payload(response)
      expect(body).to include("pr_number" => 42, "head_sha" => "a" * 40)
      expect(body["checks"].map { |check| [ check["name"], check["log_available"] ] }).to eq(
        [ [ "e2e", true ], [ "lint", false ], [ "codecov", true ] ]
      )
    end

    it "refuses outside a workflow run" do
      response = described_class.call(server_context: {})

      expect(response).to be_error
    end

    it "explains when the Job has no pull request yet" do
      job.update_columns(pr_number: nil)

      response = described_class.call(server_context: { run: run })

      expect(response).to be_error
      expect(response.content.first[:text]).to include("has no pull request yet")
    end
  end

  describe Mcp::Tools::ReadCiLogTool do
    let(:log) { (1..500).map { |i| "line #{i}" }.join("\n") + "\nFailure: expected token ghp_abcdefghijklmnopqrstuvwxyz0123456789 to work\nline 502" }

    before { allow(client).to receive(:ci_job_log).with("acme/widgets", 77).and_return(log) }

    it "returns the tail of an Actions job log with secrets redacted" do
      response = described_class.call(check_name: "e2e", tail_lines: 3, server_context: { run: run })

      expect(response).not_to be_error
      body = payload(response)
      expect(body).to include("source" => "actions_job_log", "total_lines" => 502, "returned_lines" => 3, "truncated" => true)
      expect(body["log"]).to start_with("line 500")
      expect(body["log"]).not_to include("ghp_abcdefghijklmnopqrstuvwxyz0123456789")
    end

    it "returns only matching lines with context" do
      body = payload(described_class.call(check_name: "e2e", match: "FAILURE:", server_context: { run: run }))

      expect(body["log"].lines.map(&:chomp)).to eq([
        "line 498", "line 499", "line 500", "Failure: expected token [redacted] to work", "line 502"
      ])
    end

    it "falls back to the check's own output for a non-Actions check" do
      body = payload(described_class.call(check_name: "codecov", server_context: { run: run }))

      expect(body).to include("source" => "check_output", "log" => "coverage dropped by 3%")
    end

    it "names the available checks when the requested one does not exist" do
      response = described_class.call(check_name: "rspec", server_context: { run: run })

      expect(response).to be_error
      expect(response.content.first[:text]).to include("e2e, lint, codecov")
    end

    it "says plainly when GitHub has no log left to read" do
      allow(client).to receive(:ci_job_log).and_return(nil)

      response = described_class.call(check_name: "e2e", server_context: { run: run })

      expect(response).to be_error
      expect(response.content.first[:text]).to include("no readable log")
    end
  end
end
