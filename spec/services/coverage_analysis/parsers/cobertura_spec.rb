require "rails_helper"

RSpec.describe CoverageAnalysis::Parsers::Cobertura do
  def parse(content)
    described_class.parse(content)
  end

  it "parses a minimal Cobertura XML report into a hit map" do
    xml = <<~XML
      <?xml version="1.0" ?>
      <coverage line-rate="0.75">
        <packages>
          <package name="app">
            <classes>
              <class filename="app/models/user.rb">
                <lines>
                  <line number="1" hits="5" branch="false"/>
                  <line number="2" hits="0" branch="false"/>
                  <line number="3" hits="3" branch="false"/>
                </lines>
              </class>
            </classes>
          </package>
        </packages>
      </coverage>
    XML

    result = parse(xml)

    expect(result.raw[:hit_map]).to eq({
      "app/models/user.rb" => { "1" => 5, "2" => 0, "3" => 3 }
    })
    expect(result.raw[:lf]).to eq(3)
    expect(result.raw[:lh]).to eq(2)
    expect(result.lines_pct).to eq(66.67)
  end

  it "accumulates hits for duplicate line numbers within the same class" do
    xml = <<~XML
      <?xml version="1.0" ?>
      <coverage>
        <packages><package><classes>
          <class filename="app/foo.rb">
            <lines>
              <line number="10" hits="2" branch="false"/>
              <line number="10" hits="3" branch="false"/>
            </lines>
          </class>
        </classes></package></packages>
      </coverage>
    XML

    result = parse(xml)
    expect(result.raw[:hit_map]["app/foo.rb"]["10"]).to eq(5)
    # lf counts each <line> element, even duplicates
    expect(result.raw[:lf]).to eq(2)
  end

  it "handles multiple source files in separate packages" do
    xml = <<~XML
      <?xml version="1.0" ?>
      <coverage>
        <packages>
          <package>
            <classes>
              <class filename="app/models/user.rb">
                <lines>
                  <line number="1" hits="1" branch="false"/>
                </lines>
              </class>
            </classes>
          </package>
          <package>
            <classes>
              <class filename="app/models/post.rb">
                <lines>
                  <line number="1" hits="0" branch="false"/>
                  <line number="2" hits="0" branch="false"/>
                </lines>
              </class>
            </classes>
          </package>
        </packages>
      </coverage>
    XML

    result = parse(xml)

    expect(result.raw[:hit_map].keys).to contain_exactly("app/models/user.rb", "app/models/post.rb")
    expect(result.raw[:lf]).to eq(3)
    expect(result.raw[:lh]).to eq(1)
    expect(result.lines_pct).to eq(33.33)
  end

  it "parses branch coverage from condition-coverage attributes" do
    xml = <<~XML
      <?xml version="1.0" ?>
      <coverage>
        <packages><package><classes>
          <class filename="app/bar.rb">
            <lines>
              <line number="5" hits="2" branch="true" condition-coverage="50% (1/2)"/>
              <line number="6" hits="1" branch="true" condition-coverage="100% (2/2)"/>
              <line number="7" hits="0" branch="false"/>
            </lines>
          </class>
        </classes></package></packages>
      </coverage>
    XML

    result = parse(xml)
    stats = result.raw[:file_stats]["app/bar.rb"]

    # Branch stats: line 5 contributes 1 hit / 2 total; line 6 contributes 2/2
    expect(stats[:brh]).to eq(3)
    expect(stats[:brf]).to eq(4)

    # Totals bubble up
    expect(result.raw[:brh]).to eq(3)
    expect(result.raw[:brf]).to eq(4)

    # Line stats: 3 lines, 2 hit (line 7 has 0 hits)
    expect(stats[:lf]).to eq(3)
    expect(stats[:lh]).to eq(2)
  end

  it "skips classes with an empty filename" do
    xml = <<~XML
      <?xml version="1.0" ?>
      <coverage>
        <packages><package><classes>
          <class filename="">
            <lines>
              <line number="1" hits="5" branch="false"/>
            </lines>
          </class>
          <class filename="app/real.rb">
            <lines>
              <line number="1" hits="1" branch="false"/>
            </lines>
          </class>
        </classes></package></packages>
      </coverage>
    XML

    result = parse(xml)
    expect(result.raw[:hit_map].keys).to eq(["app/real.rb"])
  end

  it "returns empty results for a coverage element with no classes" do
    xml = <<~XML
      <?xml version="1.0" ?>
      <coverage>
        <packages/>
      </coverage>
    XML

    result = parse(xml)
    expect(result.raw[:hit_map]).to be_empty
    expect(result.raw[:lf]).to eq(0)
    expect(result.lines_pct).to be_nil
  end

  it "raises ArgumentError for invalid XML" do
    expect { parse("<not valid xml<<<") }
      .to raise_error(ArgumentError, /Cobertura XML parse error/)
  end

  it "includes per-file stats in the result" do
    xml = <<~XML
      <?xml version="1.0" ?>
      <coverage>
        <packages><package><classes>
          <class filename="lib/utils.rb">
            <lines>
              <line number="1" hits="3" branch="false"/>
              <line number="2" hits="0" branch="false"/>
            </lines>
          </class>
        </classes></package></packages>
      </coverage>
    XML

    result = parse(xml)
    stats = result.raw[:file_stats]["lib/utils.rb"]

    expect(stats).to include(lf: 2, lh: 1, brf: 0, brh: 0, fnf: 0, fnh: 0)
  end
end
