# frozen_string_literal: true

require "spec_helper"

RSpec.describe "website product positioning pages" do
  def read_website(path)
    File.read(File.expand_path("../../website/#{path}", __dir__))
  end

  let(:site_copy) { read_website("lib/site.ts") }
  let(:demo) { read_website("components/demo.tsx") }
  let(:footer) { read_website("components/footer.tsx") }
  let(:layout) { read_website("src/app/layout.tsx") }
  let(:download_page) { read_website("src/app/download/page.tsx") }
  let(:faq) { read_website("src/content/docs/faq.md") }
  let(:normalized_copy) { site_copy.gsub(/\s+/, " ") }
  let(:public_positioning_copy) { [site_copy, demo, footer, layout, read_website("README.md")].join("\n") }

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
    expect(demo).to include("Open-source onboarding")
    expect(demo).to include("Read the docs")
    expect(demo).to include("Open GitHub")
    expect(demo).to include("Getting started")
    expect(download_page).to include("Download Syrus")
  end

  it "does not present the public site as a sales or lead-capture surface" do
    normalized_public_copy = public_positioning_copy.gsub(/\s+/, " ")

    expect(normalized_public_copy).to include("MIT open source and self-hosted")
    expect(normalized_public_copy).to include("file issues")
    expect(normalized_public_copy).not_to include("Request guided help")
    expect(normalized_public_copy).not_to include("Guided help")
    expect(normalized_public_copy).not_to include("guided setup")
    expect(normalized_public_copy).not_to include("Work email")
    expect(normalized_public_copy).not_to include("contactEmail")
    expect(normalized_public_copy).not_to include("apiBase")
    expect(normalized_public_copy).not_to include("api/demo")
    expect(normalized_public_copy).not_to include("mailto:")
    expect(normalized_public_copy).not_to include("sales")
    expect(layout).not_to include("Organization")
    expect(layout).not_to include("email:")
  end

  it "frames coding agents as engines Syrus orchestrates" do
    normalized_faq = faq.gsub(/\s+/, " ")

    expect(normalized_faq).to include("We don't compete with coding agents, we orchestrate them.")
    expect(normalized_faq).to include("Coding agents -- single-purpose tools that take a prompt and try to produce a change -- are engines that execute a task.")
    expect(normalized_faq).to include("Claude, Codex, Muse, and Antigravity are interchangeable provider plugins")
    expect(normalized_faq).to include("No. Syrus is an open-source self-hosted project, not a hosted product.")
    expect(normalized_faq).not_to include("| Claude Code Action |")
    expect(normalized_faq).not_to include("GitHub Copilot Coding Agent, OpenAI Codex cloud, and Google Jules are engines")
    expect(normalized_faq).not_to include("or another adapter")
    expect(normalized_faq).not_to include("whatever provider another adapter uses")
  end
end
