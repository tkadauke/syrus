require "rails_helper"

RSpec.describe "Core localization glossary", type: :unit do
  GLOSSARY_PATH = Rails.root.join("docs/i18n-glossary.md")
  FRONTEND_GUIDE_PATH = Rails.root.join("app/frontend/i18n/README.md")
  DOMAIN_TERMS = [
    "Job",
    "Run",
    "Epic",
    "Workflow",
    "landing",
    "merge train",
    "retry",
    "Repository",
    "Issue",
    "Polling",
    "Agent"
  ].freeze

  def glossary_rows(body)
    body.lines.filter_map do |line|
      cells = line.strip.split("|").map(&:strip)
      next unless line.start_with?("|") && cells.length == 5

      [ cells[1], cells[2], cells[3], cells[4] ]
    end.to_h { |english, german, latin, notes| [ english, { german:, latin:, notes: } ] }
  end

  it "records every core term and leaves every Latin decision pending" do
    rows = glossary_rows(GLOSSARY_PATH.read)

    expect(rows.keys).to include(*DOMAIN_TERMS)
    DOMAIN_TERMS.each do |term|
      expect(rows.fetch(term).fetch(:latin)).to include("PENDING LATIN REVIEW")
    end
  end

  it "records the approved German terminology and informal register" do
    body = GLOSSARY_PATH.read
    rows = glossary_rows(body)

    expect(rows.fetch("Job").fetch(:german)).to start_with("Job")
    expect(rows.fetch("Workflow").fetch(:german)).to start_with("Workflow")
    expect(rows.fetch("Epic").fetch(:german)).to start_with("Epic")
    expect(rows.fetch("Run").fetch(:german)).to include("Lauf", "Läufe")
    expect(body).to include("du/dein/dir", "informal imperatives")
  end

  it "requires competent review before Latin normalization" do
    body = GLOSSARY_PATH.read

    expect(body).to include("must not normalize")
    expect(body).to include("Latin `munus` ambiguity", "non-normative")
    %w[case number declension collisions context role-vs-job].each do |review_concern|
      expect(body.downcase).to include(review_concern)
    end
  end

  it "is discoverable beside the frontend locale catalogs" do
    guide = FRONTEND_GUIDE_PATH.read

    expect(guide).to include("../../../docs/i18n-glossary.md")
    expect(Rails.root.join("app/frontend/i18n", "../../../docs/i18n-glossary.md")).to exist
  end
end
