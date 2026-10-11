require "rails_helper"

RSpec.describe EpicMarkerParser do
  let(:repository) { Factories.repository(owner: "acme", name: "widgets") }

  def marker(text)
    described_class.parse(text: text, default_repository: repository)
  end

  def epic_marker(value)
    "<!-- syrus-epic: #{value} -->"
  end

  it "parses an explicit Epic declaration marker by name" do
    expect(marker(epic_marker("Ingestion classifier"))).to eq({
      kind: :epic_declaration,
      name: "Ingestion classifier"
    })
  end

  it "parses an explicit same-repo child reference marker" do
    expect(marker(epic_marker("#447"))).to eq({
      kind: :child_of_epic,
      owner: "acme",
      repo: "widgets",
      number: 447
    })
  end

  it "parses a bare same-repo child reference" do
    expect(marker(epic_marker("447"))).to eq({
      kind: :child_of_epic,
      owner: "acme",
      repo: "widgets",
      number: 447
    })
  end

  it "parses a cross-repo child reference" do
    expect(marker(epic_marker("tkadauke/syrus#447"))).to eq({
      kind: :child_of_epic,
      owner: "tkadauke",
      repo: "syrus",
      number: 447
    })
  end

  it "finds explicit markers anywhere in the body" do
    expect(marker("Intro text\n\n#{epic_marker("Platform intake")}\n- Depends-on: #1")).to eq({
      kind: :epic_declaration,
      name: "Platform intake"
    })
  end

  it "parses a block marker that wraps the previous Epic line format" do
    expect(marker("<!-- syrus-epic\nEpic: Platform intake\n-->")).to eq({
      kind: :epic_declaration,
      name: "Platform intake"
    })
  end

  it "uses the first marker" do
    expect(marker("#{epic_marker("First marker")}\n#{epic_marker("#447")}")).to eq({
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

  it "does not parse a natural-language Epic line" do
    expect(marker("Epic: #447")).to be_nil
  end

  it "does not parse quoted text as an Epic marker" do
    expect(marker("> Epic: #447")).to be_nil
  end

  it "does not parse markdown headings as an Epic marker" do
    expect(marker("## Epic: #447")).to be_nil
  end

  it "does not parse issue-template fields as an Epic marker" do
    expect(marker("### Epic\n\n#447")).to be_nil
  end

  it "does not parse paragraphs mentioning Epic as an Epic marker" do
    expect(marker("This rollout belongs with the Epic: #447 planning work.")).to be_nil
  end

  it "returns nil for a missing reference number" do
    expect(marker(epic_marker("#"))).to be_nil
  end

  it "returns nil for a malformed slug reference" do
    expect(marker(epic_marker("foo#bar"))).to be_nil
  end

  it "does not run a whole-body regex over long non-marker issue text" do
    expect(marker("x" * 100_000)).to be_nil
  end

  it "bounds absurd marker values" do
    expect(marker(epic_marker("x" * 100_000))).to eq({
      kind: :epic_declaration,
      name: "x" * described_class::MAX_MARKER_VALUE_BYTES
    })
  end
end
