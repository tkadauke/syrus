# frozen_string_literal: true

require "spec_helper"

RSpec.describe "website home page" do
  subject(:content) { File.read(File.expand_path("../../website/src/pages/index.md", __dir__)) }

  let(:normalized_content) { content.gsub(/\s+/, " ") }

  it "explains Syrus as a self-hosted harness for GitHub-to-PR agent work" do
    expect(normalized_content).to include("self-hosted automation harness for agentic coding work")
    expect(normalized_content).to include("turns GitHub issues, PR feedback, scheduled tasks, retries, and rebases into agent runs")
    expect(normalized_content).to include("captures the commits and opens or updates the pull request")
    expect(normalized_content).to include("The agent writes code; Syrus handles the job control around it.")
  end

  it "makes the issue-to-PR flow understandable without internal context" do
    expect(content).to include("GitHub issue or task")
    expect(content).to include("-> Syrus poller")
    expect(content).to include("-> prepared workspace")
    expect(content).to include("-> commit, push, pull request")
    expect(normalized_content).to include("not just an agent prompt, but the machinery around the prompt")
  end

  it "uses real current pages for primary calls to action" do
    expect(content).to include("[Try it locally](/docs/deployment/try-it-locally)")
    expect(content).to include("[Read the docs](/docs/getting-started)")
    expect(content).to include("[Docker Compose guide](/docs/deployment/docker-compose)")
    expect(content).to include("[Kubernetes guide](/docs/deployment/kubernetes)")
    expect(content).to include("[Star on GitHub](https://github.com/tkadauke/syrus)")
  end
end
