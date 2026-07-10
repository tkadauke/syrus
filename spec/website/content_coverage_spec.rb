# frozen_string_literal: true

require "spec_helper"

RSpec.describe "website content coverage" do
  def read_website(path)
    File.read(File.expand_path("../../website/#{path}", __dir__))
  end

  it "keeps the public docs navigation contract in the website README" do
    readme = read_website("README.md")

    expect(readme).to include("Next.js 15")
    expect(readme).to include("Information Architecture")
    expect(readme).to include("Home")
    expect(readme).to include("Download")
    expect(readme).to include("Request a demo")
    expect(readme).to include("Copy lives in `lib/site.ts`")
    expect(readme).to include("A feature is not done if the user-facing page that explains it is stale")
  end

  it "has current Next.js surfaces for the basic visitor questions" do
    pages = {
      "app/page.tsx" => ["<Hero", "<TeamWorkflow", "<Features", "<EntryPoints", "<Demo"],
      "app/download/page.tsx" => ["Download Syrus", "macOS", "Windows", "CLI"],
      "lib/site.ts" => [
        "Ship more of your roadmap.",
        "Proposes epics & tickets",
        "Multiply your output",
        "Approve it — it lands itself",
        "Issue or ticket",
        "Scheduled task"
      ],
      "components/nav.tsx" => ["How it works", "Why Syrus", "Entry points", "Request a demo"]
    }

    pages.each do |path, expected_sections|
      content = read_website(path)

      expected_sections.each do |section|
        expect(content).to include(section)
      end
    end
  end

  it "requires agent guidance to keep website docs current for product changes" do
    guide = File.read(File.expand_path("../../CLAUDE.md", __dir__))

    expect(guide).to include("Public website/docs stay current")
    expect(guide).to include("Product-facing behavior changes")
    expect(guide).to include("update `website/` in the same PR")
  end

  it "keeps markdown pages free of unfinished stub comments" do
    markdown_files = Dir[File.expand_path("../../website/**/*.md", __dir__)].reject { |f| f.include?("/node_modules/") }

    offenders = markdown_files.select do |path|
      File.read(path).match?(/<!--\s*(STUB|TODO)/i)
    end

    expect(offenders).to be_empty
  end
end
