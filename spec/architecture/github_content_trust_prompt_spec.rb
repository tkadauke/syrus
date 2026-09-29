require "rails_helper"

RSpec.describe "GitHub-sourced prompt trust boundaries" do
  GITHUB_CONTENT_PATTERNS = [
    /@issue\./,
    /@job\.issue_body/,
    /@body/,
    /GitHub summary:/,
    /New issue:/,
    /Current PR body:/,
    /PR review thread/,
    /Anchored diff comments:/
  ].freeze

  def prompt_files
    Dir.glob(Rails.root.join("app/services/prompts/**/*.rb"))
      .reject { |path| path.end_with?("github_content_trust.rb") }
  end

  it "marks every prompt template that renders GitHub-sourced content" do
    missing = prompt_files.filter_map do |path|
      source = File.read(path)
      next unless GITHUB_CONTENT_PATTERNS.any? { |pattern| source.match?(pattern) }
      next if source.include?(Prompts::GithubContentTrust::MARKER)

      Pathname(path).relative_path_from(Rails.root).to_s
    end

    expect(missing).to be_empty
  end
end
