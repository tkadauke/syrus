# frozen_string_literal: true

require "spec_helper"

RSpec.describe "website home page" do
  def read_website(path)
    File.read(File.expand_path("../../website/#{path}", __dir__))
  end

  let(:page) { read_website("src/app/page.tsx") }
  let(:site_copy) { read_website("lib/site.ts") }
  let(:nav) { read_website("components/nav.tsx") }
  let(:normalized_copy) { site_copy.gsub(/\s+/, " ") }

  it "assembles the current Next.js landing page from the product sections" do
    expect(page).to include("<Hero")
    expect(page).to include("<TeamWorkflow")
    expect(page).to include("<Features")
    expect(page).to include("<EntryPoints")
    expect(page).to include("<Demo")
  end

  it "explains Syrus as owner-controlled AI work from goal to merged pull request" do
    expect(site_copy).to include("Run coding agents on your repos.")
    expect(normalized_copy).to include("turning issues, chats, and video walkthroughs into tracked pull requests")
    expect(normalized_copy).to include("review policy")
    expect(normalized_copy).to include("merge queue")
    expect(normalized_copy).to include("Know what every feature cost")
  end

  it "uses real current anchors and pages for primary calls to action" do
    expect(nav).to include('href: "/#how"')
    expect(nav).to include('href: "/#features"')
    expect(nav).to include('href: "/#entry-points"')
    expect(nav).to include('href="/#walkthrough-demo"')
    expect(nav).to include("<DownloadButton")

    hero = read_website("components/hero.tsx")
    expect(hero).to include("<DownloadCTA")
    expect(hero).to include('href="/#walkthrough-demo"')
    expect(hero).to include("Watch the product demo")

    expect(read_website("components/footer.tsx")).to include('href: "/download"')
  end

  it "has a matching section or page for every advertised anchor" do
    expect(read_website("components/team-workflow.tsx")).to include('section id="how"')
    expect(read_website("components/features.tsx")).to include('section id="features"')
    expect(read_website("components/entry-points.tsx")).to include('section id="entry-points"')
    expect(read_website("components/demo.tsx")).to include('section id="demo"')
    expect(read_website("src/app/download/page.tsx")).to include("Download Syrus")
  end
end
