# frozen_string_literal: true

require "spec_helper"

RSpec.describe "website home page" do
  subject(:content) { File.read(File.expand_path("../../website/src/pages/index.md", __dir__)) }

  let(:normalized_content) { content.gsub(/\s+/, " ") }

  it "opens with a plain-language product sentence" do
    expect(normalized_content).to include(
      "Syrus is a self-hosted automation harness that turns GitHub issues, " \
      "operator prompts, schedules, and PR feedback into coding-agent runs " \
      "that open or update pull requests."
    )
  end

  it "explains the issue-to-PR loop without requiring internal model knowledge" do
    expect(content).to include("GitHub issue")
    expect(content).to include("-> Syrus Job")
    expect(content).to include("-> agent writes code in a cloned workspace")
    expect(content).to include("-> pull request")
    expect(normalized_content).to include(
      "You do not need to understand the internal Job and Workflow model to use it."
    )
  end

  it "explains why self-hosting matters for control and auditability" do
    expect(normalized_content).to include("Your repositories stay registered in your Syrus instance.")
    expect(normalized_content).to include("Your GitHub credentials and agent-provider keys are stored and encrypted there.")
    expect(normalized_content).to include("Your transcripts, diffs, logs, costs, retries, and operational history remain in infrastructure you control.")
  end

  it "covers the major use cases" do
    expect(content).to include("**Issue ingestion.**")
    expect(content).to include("**Direct jobs and chats.**")
    expect(content).to include("**Scheduled maintenance.**")
    expect(content).to include("**PR feedback and retries.**")
  end

  it "links to current evaluation, docs, and source pages" do
    expect(content).to include("[Try it locally](/docs/deployment/try-it-locally)")
    expect(content).to include("[Get started](/docs/getting-started)")
    expect(content).to include("[Read the docs](/docs/what-is-syrus)")
    expect(content).to include("[View source](https://github.com/tkadauke/syrus)")
  end
end
