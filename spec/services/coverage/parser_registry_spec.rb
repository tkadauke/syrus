require "rails_helper"

RSpec.describe Coverage::ParserRegistry do
  before do
    # Reference parsers to trigger autoload and self-registration
    Coverage::LcovParser
    Coverage::CoberturaParser
  end

  it "resolves the lcov format to LcovParser" do
    expect(described_class.for("lcov")).to eq(Coverage::LcovParser)
  end

  it "resolves the cobertura format to CoberturaParser" do
    expect(described_class.for("cobertura")).to eq(Coverage::CoberturaParser)
  end

  it "returns nil for an unknown format" do
    expect(described_class.for("unknown_format_xyz")).to be_nil
  end

  it "lists all registered formats" do
    expect(described_class.formats).to include("lcov", "cobertura")
  end

  it "dispatches to the correct parser" do
    parser_class = described_class.for("lcov")
    result = parser_class.new("SF:app/foo.rb\nDA:1,1\nend_of_record\n").parse
    expect(result[:files]).to have_key("app/foo.rb")
  end
end
