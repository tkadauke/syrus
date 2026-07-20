require "rails_helper"

RSpec.describe FtsQueryParser do
  let(:parser) do
    Class.new { include FtsQueryParser }
  end

  def parse(input)
    parser.send(:parse_fts_query, input)
  end

  it "returns an empty string for an empty input" do
    expect(parse("")).to eq("")
  end

  it "returns an empty string for nil" do
    expect(parse(nil)).to eq("")
  end

  it "passes through a plain single word unchanged" do
    expect(parse("foo")).to eq("foo")
  end

  it "passes through multiple plain words separated by spaces" do
    expect(parse("foo bar baz")).to eq("foo bar baz")
  end

  it "preserves an already-quoted phrase" do
    expect(parse('"foo bar"')).to eq('"foo bar"')
  end

  it "wraps a hyphenated token in quotes so FTS5 treats it as a phrase" do
    expect(parse("foo-bar")).to eq('"foo-bar"')
  end

  it "handles mixed plain words, quoted phrases, and hyphenated tokens" do
    expect(parse('foo "bar baz" JOB-123')).to eq('foo "bar baz" "JOB-123"')
  end

  it "captures the rest of the string when a quote is never closed" do
    expect(parse('"unclosed phrase')).to eq('"unclosed phrase"')
  end

  it "handles a quoted phrase that is followed by plain words" do
    expect(parse('"hello world" foo')).to eq('"hello world" foo')
  end

  it "handles multiple quoted phrases" do
    expect(parse('"first phrase" "second phrase"')).to eq('"first phrase" "second phrase"')
  end

  it "skips empty quoted strings" do
    expect(parse('""')).to eq("")
  end

  it "trims whitespace inside unquoted segments when splitting into tokens" do
    expect(parse("  foo   bar  ")).to eq("foo bar")
  end

  it "quotes a token that contains a hyphen even when mixed with plain tokens" do
    expect(parse("alpha non-breaking beta")).to eq('alpha "non-breaking" beta')
  end
end
