require "rails_helper"

RSpec.describe Skills::SkillMarkdown do
  let(:contents) do
    <<~MARKDOWN
      ---
      name: audit-dependencies
      description: Reports outdated or vulnerable dependencies.
      parameters:
        - key: severity
          type: select
          options: [low, medium, high]
          required: false
      ---

      Investigate the dependency manifests and report anything outdated or
      flagged as vulnerable at or above {{severity}}.
    MARKDOWN
  end

  it "parses frontmatter and body into a Definition" do
    definition = described_class.parse(contents, name: "audit-dependencies")

    expect(definition).to be_a(Skills::Definition)
    expect(definition.name).to eq("audit-dependencies")
    expect(definition.description).to eq("Reports outdated or vulnerable dependencies.")
    expect(definition.parameters.size).to eq(1)
    expect(definition.parameters.first.key).to eq("severity")
    expect(definition.parameters.first.options).to eq(%w[low medium high])
    expect(definition.instructions).to include("{{severity}}")
  end

  it "defaults name to the requested name when frontmatter omits it" do
    unnamed = <<~MARKDOWN
      ---
      description: Does a thing.
      ---
      Do the thing.
    MARKDOWN

    definition = described_class.parse(unnamed, name: "do-thing")

    expect(definition.name).to eq("do-thing")
    expect(definition.parameters).to eq([])
  end

  it "raises when frontmatter is missing" do
    expect {
      described_class.parse("just a body, no frontmatter", name: "x")
    }.to raise_error(described_class::ParseError, /frontmatter/)
  end

  it "raises when description is missing" do
    no_description = <<~MARKDOWN
      ---
      name: x
      ---
      Body.
    MARKDOWN

    expect {
      described_class.parse(no_description, name: "x")
    }.to raise_error(described_class::ParseError, /description/)
  end

  it "raises when the frontmatter name does not match the requested name" do
    expect {
      described_class.parse(contents, name: "something-else")
    }.to raise_error(described_class::ParseError, /does not match/)
  end

  it "raises on invalid YAML frontmatter" do
    broken = <<~MARKDOWN
      ---
      name: [unterminated
      ---
      Body.
    MARKDOWN

    expect {
      described_class.parse(broken, name: "x")
    }.to raise_error(described_class::ParseError, /YAML parse error/)
  end

  it "propagates a ParameterSchema::ParseError for a malformed parameters block" do
    bad_params = <<~MARKDOWN
      ---
      name: x
      description: does a thing
      parameters:
        - key: ""
          type: string
      ---
      Body.
    MARKDOWN

    expect {
      described_class.parse(bad_params, name: "x")
    }.to raise_error(Skills::ParameterSchema::ParseError)
  end
end
