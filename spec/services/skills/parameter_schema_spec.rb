require "rails_helper"

RSpec.describe Skills::ParameterSchema do
  describe ".normalize" do
    it "normalizes a minimal field with defaults" do
      fields = described_class.normalize([ { "key" => "question", "type" => "string" } ])

      expect(fields.size).to eq(1)
      field = fields.first
      expect(field.key).to eq("question")
      expect(field.type).to eq("string")
      expect(field.required).to eq(false)
      expect(field.label).to eq("Question")
      expect(field.options).to be_nil
    end

    it "accepts symbol keys, same shape as InputSources::Linear#config_schema" do
      fields = described_class.normalize([ { key: "api_key", type: "string", required: true, label: "API key" } ])

      expect(fields.first.key).to eq("api_key")
      expect(fields.first.required).to eq(true)
      expect(fields.first.label).to eq("API key")
    end

    it "requires options for a select field" do
      expect {
        described_class.normalize([ { "key" => "mode", "type" => "select" } ])
      }.to raise_error(described_class::ParseError, /options/)
    end

    it "normalizes select options into strings" do
      fields = described_class.normalize([ { "key" => "mode", "type" => "select", "options" => [ "a", "b" ] } ])

      expect(fields.first.options).to eq(%w[a b])
    end

    it "rejects an unknown type" do
      expect {
        described_class.normalize([ { "key" => "x", "type" => "bogus" } ])
      }.to raise_error(described_class::ParseError, /must be one of/)
    end

    it "rejects a blank key" do
      expect {
        described_class.normalize([ { "key" => "", "type" => "string" } ])
      }.to raise_error(described_class::ParseError, /key/)
    end

    it "rejects a duplicated key" do
      expect {
        described_class.normalize([
          { "key" => "x", "type" => "string" },
          { "key" => "x", "type" => "string" }
        ])
      }.to raise_error(described_class::ParseError, /duplicated/)
    end

    it "rejects a non-array" do
      expect {
        described_class.normalize({ "key" => "x" })
      }.to raise_error(described_class::ParseError, /must be an array/)
    end
  end

  describe ".validate!" do
    let(:fields) do
      described_class.normalize([
        { "key" => "question", "type" => "string", "required" => true },
        { "key" => "mode", "type" => "select", "options" => %w[fast thorough] }
      ])
    end

    it "passes when required params are present and valid" do
      expect(described_class.validate!(fields, { "question" => "why?", "mode" => "fast" })).to eq(true)
    end

    it "raises when a required param is missing" do
      expect {
        described_class.validate!(fields, {})
      }.to raise_error(described_class::ValidationError, /question.*is required/)
    end

    it "raises when a select value is not one of the declared options" do
      expect {
        described_class.validate!(fields, { "question" => "why?", "mode" => "bogus" })
      }.to raise_error(described_class::ValidationError, /mode.*must be one of/)
    end

    it "raises when an undeclared param is submitted" do
      expect {
        described_class.validate!(fields, { "question" => "why?", "extra" => "1" })
      }.to raise_error(described_class::ValidationError, /extra.*is not a declared parameter/)
    end

    context "with an integer field" do
      let(:fields) do
        described_class.normalize([
          { "key" => "question", "type" => "string", "required" => true },
          { "key" => "retries", "type" => "integer" }
        ])
      end

      it "passes when the value is an integer string" do
        expect(described_class.validate!(fields, { "question" => "why?", "retries" => "3" })).to eq(true)
      end

      it "raises when the value is not an integer" do
        expect {
          described_class.validate!(fields, { "question" => "why?", "retries" => "soon" })
        }.to raise_error(described_class::ValidationError, /retries.*must be an integer/)
      end
    end

    it "accumulates every problem in one error" do
      expect {
        described_class.validate!(fields, { "extra" => "1" })
      }.to raise_error(described_class::ValidationError, /question.*extra/m)
    end
  end
end
