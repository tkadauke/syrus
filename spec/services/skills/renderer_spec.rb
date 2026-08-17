require "rails_helper"

RSpec.describe Skills::Renderer do
  def definition(instructions, parameters: [])
    Skills::Definition.new(
      name: "investigate",
      description: "desc",
      parameters: Skills::ParameterSchema.normalize(parameters),
      instructions: instructions
    )
  end

  describe ".render" do
    it "substitutes a declared placeholder with the submitted arg" do
      d = definition("Question: {{question}}", parameters: [ { "key" => "question", "type" => "string", "required" => true } ])

      expect(described_class.render(d, { "question" => "What does the widget do?" })).to eq("Question: What does the widget do?")
    end

    it "accepts symbol-keyed args" do
      d = definition("Question: {{question}}", parameters: [ { "key" => "question", "type" => "string" } ])

      expect(described_class.render(d, { question: "Is it on fire?" })).to eq("Question: Is it on fire?")
    end

    it "falls back to the field's declared default when no arg was submitted" do
      d = definition(
        "Mode: {{mode}}",
        parameters: [ { "key" => "mode", "type" => "select", "options" => %w[fast thorough], "default" => "fast" } ]
      )

      expect(described_class.render(d, {})).to eq("Mode: fast")
    end

    it "leaves a placeholder with no declared parameter and no default untouched" do
      d = definition("Question: {{question}}", parameters: [ { "key" => "question", "type" => "string" } ])

      expect(described_class.render(d, {})).to eq("Question: {{question}}")
    end

    it "leaves placeholders for undeclared keys untouched" do
      d = definition("{{unknown}}")

      expect(described_class.render(d, { "unknown" => "should not substitute" })).to eq("{{unknown}}")
    end

    it "substitutes multiple distinct placeholders" do
      d = definition(
        "{{first}} and {{second}}",
        parameters: [ { "key" => "first", "type" => "string" }, { "key" => "second", "type" => "string" } ]
      )

      expect(described_class.render(d, { "first" => "a", "second" => "b" })).to eq("a and b")
    end
  end
end
