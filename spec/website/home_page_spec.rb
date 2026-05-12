# frozen_string_literal: true

require "spec_helper"

RSpec.describe "website home page" do
  subject(:content) { File.read(File.expand_path("../../website/src/pages/index.astro", __dir__)) }

  it "uses a custom Astro page instead of the markdown stub" do
    markdown_stub = File.expand_path("../../website/src/pages/index.md", __dir__)

    expect(File).not_to exist(markdown_stub)
    expect(content).to include("<StarlightPage")
    expect(content).to include("template: \"splash\"")
    expect(content).to include("<div class=\"home\">")
    expect(content).not_to include("<main class=\"home\">")
  end

  it "includes the planned home page sections and links" do
    expect(content).to include("Bis dat qui cito dat.")
    expect(content).to include("Try it locally ->")
    expect(content).to include("Star on GitHub")
    expect(content).to include("What is Syrus?")
    expect(content).to include("Why Syrus")
    expect(content).to include("Show the work")
    expect(content).to include("Honest status")
    expect(content).to include("Deploy with Docker Compose")
    expect(content).to include("Run on Kubernetes")
    expect(content).to include("/about")
  end

  it "anchors the visual proof in a real Syrus pull request" do
    expect(content).to include("https://github.com/tkadauke/syrus/pull/165")
    expect(content).to include("PR #165")
    expect(content).to include("competitive landscape scan")
  end

  it "embeds the issue to pull request flow diagram as svg" do
    expect(content).to include("<svg class=\"flow\"")
    expect(content).to include("issue")
    expect(content).to include("poller")
    expect(content).to include("agent")
    expect(content).to include("PR")
  end

  it "references committed redacted screenshot assets" do
    %w[job-page dashboard].each do |name|
      asset = File.expand_path("../../website/public/screenshots/#{name}.svg", __dir__)

      expect(File).to exist(asset)
      expect(content).to include("/screenshots/#{name}.svg")
      expect(File.read(asset)).to include("width=\"1440\" height=\"900\"")
      expect(File.read(asset)).to include("REDACTED")
    end
  end
end
