require "rails_helper"

RSpec.describe EpicMarkerParser do
  let(:repository) { Factories.repository(owner: "acme", name: "widgets") }

  def marker(text)
    described_class.parse(text: text, default_repository: repository)
  end

  it "parses an Epic declaration by name" do
    expect(marker("Epic: Ingestion classifier")).to eq({
      kind: :epic_declaration,
      name: "Ingestion classifier"
    })
  end

  it "parses a same-repo child reference" do
    expect(marker("Epic: #447")).to eq({
      kind: :child_of_epic,
      owner: "acme",
      repo: "widgets",
      number: 447
    })
  end

  it "parses a cross-repo child reference" do
    expect(marker("Epic: tkadauke/syrus#447")).to eq({
      kind: :child_of_epic,
      owner: "tkadauke",
      repo: "syrus",
      number: 447
    })
  end

  it "finds markers anywhere in the body" do
    expect(marker("Intro text\n\n- Epic: Platform intake\n- Depends-on: #1")).to eq({
      kind: :epic_declaration,
      name: "Platform intake"
    })
  end

  it "uses the first marker" do
    expect(marker("Epic: First marker\nEpic: #447")).to eq({
      kind: :epic_declaration,
      name: "First marker"
    })
  end

  it "returns nil when no marker exists" do
    expect(marker("Depends-on: #447")).to be_nil
  end

  it "does not match Epic inside another word" do
    expect(marker("NotEpic: #447")).to be_nil
  end

  it "returns nil for a missing reference number" do
    expect(marker("Epic: #")).to be_nil
  end

  it "returns nil for a malformed slug reference" do
    expect(marker("Epic: foo#bar")).to be_nil
  end

  it "returns nil for numeric-only values" do
    expect(marker("Epic: 447")).to be_nil
  end
end
