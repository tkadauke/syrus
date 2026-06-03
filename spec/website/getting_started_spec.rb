# frozen_string_literal: true

require "spec_helper"

RSpec.describe "website getting started guide" do
  subject(:content) { File.read(File.expand_path("../../website/src/content/docs/getting-started.md", __dir__)) }

  let(:normalized_content) { content.gsub(/\s+/, " ") }

  it "walks users through the first successful run sequence" do
    expect(normalized_content).to include("choose a path, boot Syrus, add credentials, register a repository, label one small issue, and confirm the PR opens")
    expect(content).to include("## 1. Start Syrus")
    expect(content).to include("## 2. Add Credentials")
    expect(content).to include("## 3. Register A Repository")
    expect(content).to include("## 4. Trigger The First Job")
    expect(content).to include("## 5. Watch The Run")
    expect(content).to include("prepare -> implement -> summarize -> pr_open")
    expect(normalized_content).to include("You are done when the Job shows a successful Workflow and includes a PR link.")
  end

  it "aligns onboarding with repository setup and prepare behavior" do
    expect(content).to include("The default is\n  `syrus`.")
    expect(content).to include("prepare:")
    expect(normalized_content).to include("`prepare: []` or `prepare: false` opts out")
    expect(normalized_content).to include("Syrus auto-detects one setup command from common files")
  end

  it "describes deployment status honestly" do
    expect(normalized_content).to include("Compose and Kubernetes pages currently document target flows for packaging that is still being polished")
    expect(normalized_content).to include("the exact deployment commands may change as those artifacts land")
  end
end
