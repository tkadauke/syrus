# frozen_string_literal: true

require "spec_helper"

RSpec.describe "website content coverage" do
  def read_website(path)
    File.read(File.expand_path("../../website/#{path}", __dir__))
  end

  it "keeps the public docs navigation contract in the website README" do
    readme = read_website("README.md")

    expect(readme).to include("Information Architecture")
    expect(readme).to include("What is Syrus?")
    expect(readme).to include("Why use Syrus?")
    expect(readme).to include("Getting Started")
    expect(readme).to include("Troubleshooting")
    expect(readme).to include("A feature is not done if the user-facing page that explains it is stale")
  end

  it "has product pages for the basic visitor questions" do
    pages = {
      "src/pages/index.md" => ["The Loop", "Start Small", "Label GitHub issues"],
      "src/content/docs/index.md" => ["Start Here", "Product Manual", "Operating Syrus"],
      "src/content/docs/what-is-syrus.md" => ["The 30-Second Version", "What Syrus Owns", "The Core Terms"],
      "src/content/docs/why-use-syrus.md" => ["Own The Keys", "Keep GitHub As The Workflow", "Good Fits"],
      "src/content/docs/features.md" => ["Epics", "Chats", "GitHub App And PAT Behavior"],
      "src/content/docs/getting-started.md" => ["First Successful Run", "Create the first admin", "Review the PR"]
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
    markdown_files = Dir[File.expand_path("../../website/**/*.md", __dir__)]

    offenders = markdown_files.select do |path|
      File.read(path).match?(/<!--\s*(STUB|TODO)/i)
    end

    expect(offenders).to be_empty
  end
end
