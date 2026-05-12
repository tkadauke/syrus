# frozen_string_literal: true

require "spec_helper"

RSpec.describe "website evaluate page" do
  subject(:content) { File.read(File.expand_path("../../website/src/pages/evaluate.md", __dir__)) }

  let(:normalized_content) { content.gsub(/\s+/, " ") }

  it "keeps the local evaluation flow to exactly three command blocks" do
    expect(content.scan(/^```bash$/).count).to eq(3)

    expect(content).to include("## 1. Get an Anthropic API key")
    expect(content).to include("export ANTHROPIC_API_KEY=sk-ant-...")

    expect(content).to include("## 2. Run Syrus against any local repo")
    expect(content).to include("ghcr.io/tkadauke/syrus:eval-latest")

    expect(content).to include("## 3. Inspect / apply the diff")
    expect(normalized_content).to include("--output ./syrus.diff && git apply ./syrus.diff")
  end

  it "shows captured sample output before the single follow-up CTA" do
    sample_index = content.index("## Sample output")
    cta_index = content.index("[Like what you see? Deploy with Docker Compose")

    expect(sample_index).not_to be_nil
    expect(cta_index).not_to be_nil
    expect(sample_index).to be < cta_index

    expect(content).to include("starting local_dev run 1 step prepare")
    expect(content).to include("invoking agent for ad hoc job")
    expect(content).to include("diff --git a/CHANGELOG.md b/CHANGELOG.md")
    expect(content).to include("+++ b/CHANGELOG.md")
    expect(content).to include("- Add upcoming release notes here.")

    expect(content.scan(%r{\[[^\]]+\]\(/docs/deployment/docker-compose\)}).count).to eq(1)
    expect(content).not_to include("/docs/deployment/kubernetes")
  end

  it "covers the expected troubleshooting failures without becoming a second manual" do
    troubleshooting = content.split("## Troubleshooting", 2).last

    expect(troubleshooting).to include("Docker is not installed or not running")
    expect(troubleshooting).to include("The API key is invalid")
    expect(troubleshooting).to include("The container has no internet access")
    expect(troubleshooting).to include("The image will not pull")
    expect(troubleshooting.scan(/^\*\*/).count).to be_between(3, 5).inclusive
  end
end
