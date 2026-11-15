require "rails_helper"

RSpec.describe Coworkers::RepositoryConfiguration do
  def parse(yaml) = described_class.parse(value: YAML.safe_load(yaml), version: 1, scope: nil)

  it "parses explicitly enabled coworker review configuration" do
    config = parse(<<~YAML)
      enabled: true
      rounds: 3
      required: true
      criteria:
        - Check operational fit.
    YAML

    expect(config).to eq(described_class::Config.new(
      enabled: true, rounds: 3, required: true, criteria: [ "Check operational fit." ]
    ))
  end

  it "keeps coworker review disabled unless explicitly enabled" do
    expect(parse("rounds: 2\n").enabled).to be(false)
  end

  it "accepts a zero round budget when explicitly disabled" do
    expect(parse("enabled: false\nrounds: 0\n")).to have_attributes(enabled: false, rounds: 0)
  end

  it "rejects an invalid round budget deterministically" do
    expect { parse("enabled: true\nrounds: 11\n") }
      .to raise_error(SyrusYml::ParseError, /coworker_review\.rounds: must be between 1 and 10/)
    expect { parse("enabled: true\nrounds: 0\n") }
      .to raise_error(SyrusYml::ParseError, /must be between 1 and 10/)
    expect { parse("enabled: true\nrounds: many\n") }
      .to raise_error(SyrusYml::ParseError, /rounds: must be an integer/)
  end

  it "rejects non-mapping and malformed criteria" do
    expect { parse("[]") }.to raise_error(SyrusYml::ParseError, /must be a mapping/)
    expect { parse("criteria: nope\n") }.to raise_error(SyrusYml::ParseError, /criteria: must be an array of strings/)
  end

  it "keeps the legacy top-level key as a plugin-owned alias" do
    expect(described_class.legacy_keys).to eq([ "coworker_review" ])
    expect(described_class.key).to eq("coworkers.review")
  end
end
