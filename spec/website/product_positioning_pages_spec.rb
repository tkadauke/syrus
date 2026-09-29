# frozen_string_literal: true

require "spec_helper"

RSpec.describe "website product positioning pages" do
  def read_website(path)
    File.read(File.expand_path("../../website/#{path}", __dir__))
  end

  let(:site_copy) { read_website("lib/site.ts") }
  let(:demo) { read_website("components/demo.tsx") }
  let(:download_page) { read_website("src/app/download/page.tsx") }
  let(:faq) { read_website("src/content/docs/faq.md") }
  let(:normalized_copy) { site_copy.gsub(/\s+/, " ") }

  it "links the explanatory sections from the home navigation" do
    nav = read_website("components/nav.tsx")

    expect(nav).to include("How it works")
    expect(nav).to include("/#how")
    expect(nav).to include("Why Syrus")
    expect(nav).to include("/#features")
  end

  it "explains what Syrus is using current product terminology" do
    expect(normalized_copy).to include("epics and tickets")
    expect(normalized_copy).to include("Jobs")
    expect(normalized_copy).to include("tracked job")
    expect(normalized_copy).to include("pull request")
    expect(normalized_copy).to include("landing queue")
    expect(normalized_copy).to include("full transcript, diff, and review")
  end

  it "helps visitors decide whether Syrus fits their workflow" do
    expect(normalized_copy).to include("Self-hosted on your infrastructure")
    expect(normalized_copy).to include("GitHub")
    expect(normalized_copy).to include("plugin-backed model provider you choose")
    expect(demo).to include("Request guided help")
    expect(download_page).to include("Download Syrus")
  end

  it "frames coding agents as engines Syrus orchestrates" do
    normalized_faq = faq.gsub(/\s+/, " ")

    expect(normalized_faq).to include("We don't compete with coding agents, we orchestrate them.")
    expect(normalized_faq).to include("Coding agents -- single-purpose tools that take a prompt and try to produce a change -- are engines that execute a task.")
    expect(normalized_faq).to include("Claude, Codex, Muse, and Antigravity are interchangeable provider plugins")
    expect(normalized_faq).not_to include("| Claude Code Action |")
    expect(normalized_faq).not_to include("GitHub Copilot Coding Agent, OpenAI Codex cloud, and Google Jules are engines")
    expect(normalized_faq).not_to include("or another adapter")
    expect(normalized_faq).not_to include("whatever provider another adapter uses")
  end
end
