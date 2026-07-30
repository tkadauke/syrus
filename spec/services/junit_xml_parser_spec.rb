require "rails_helper"

RSpec.describe JunitXmlParser do
  def parse(xml)
    described_class.parse(xml)
  end

  describe "basic testsuite parsing" do
    let(:xml) do
      <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <testsuite name="MySpec" tests="3" time="0.5">
          <testcase classname="MySpec" name="passes" time="0.1"/>
          <testcase classname="MySpec" name="fails" time="0.2">
            <failure message="Expected true to be false">line 5 in spec/my_spec.rb</failure>
          </testcase>
          <testcase classname="MySpec" name="is skipped" time="0.05">
            <skipped/>
          </testcase>
        </testsuite>
      XML
    end

    it "returns correct counts" do
      result = parse(xml)
      expect(result.total_count).to eq(3)
      expect(result.passed_count).to eq(1)
      expect(result.failed_count).to eq(1)
      expect(result.skipped_count).to eq(1)
      expect(result.error_count).to eq(0)
    end

    it "parses total duration from suite time attribute" do
      result = parse(xml)
      expect(result.duration_ms).to eq(500)
    end

    it "produces a ParsedCase for each testcase" do
      result = parse(xml)
      expect(result.cases.size).to eq(3)
    end

    it "parses a passing test case" do
      passing = parse(xml).cases.find { |c| c.name == "passes" }
      expect(passing).to have_attributes(
        name: "passes",
        suite_name: "MySpec",
        status: "passed",
        duration_ms: 100,
        failure_message: nil,
        failure_backtrace: nil
      )
    end

    it "parses a failing test case with message and backtrace" do
      failing = parse(xml).cases.find { |c| c.name == "fails" }
      expect(failing).to have_attributes(
        status: "failed",
        failure_message: "Expected true to be false",
        failure_backtrace: "line 5 in spec/my_spec.rb"
      )
    end

    it "parses a skipped test case" do
      skipped = parse(xml).cases.find { |c| c.name == "is skipped" }
      expect(skipped.status).to eq("skipped")
    end
  end

  describe "<testsuites> wrapper" do
    let(:xml) do
      <<~XML
        <testsuites time="1.0">
          <testsuite name="SuiteA" time="0.6">
            <testcase classname="SuiteA" name="a1" time="0.3"/>
            <testcase classname="SuiteA" name="a2" time="0.3">
              <failure message="oops">trace</failure>
            </testcase>
          </testsuite>
          <testsuite name="SuiteB" time="0.4">
            <testcase classname="SuiteB" name="b1" time="0.4"/>
          </testsuite>
        </testsuites>
      XML
    end

    it "aggregates test cases from all suites" do
      result = parse(xml)
      expect(result.total_count).to eq(3)
      expect(result.passed_count).to eq(2)
      expect(result.failed_count).to eq(1)
    end

    it "sums duration across suites" do
      result = parse(xml)
      expect(result.duration_ms).to eq(1000)
    end

    it "preserves suite_name per testcase" do
      result = parse(xml)
      expect(result.cases.map(&:suite_name)).to contain_exactly("SuiteA", "SuiteA", "SuiteB")
    end
  end

  describe "<error> element" do
    let(:xml) do
      <<~XML
        <testsuite name="ErrorSpec" tests="1" time="0.1">
          <testcase classname="ErrorSpec" name="crashes" time="0.1">
            <error message="RuntimeError">full backtrace here</error>
          </testcase>
        </testsuite>
      XML
    end

    it "parses error status" do
      result = parse(xml)
      tc = result.cases.first
      expect(tc.status).to eq("error")
      expect(tc.failure_message).to eq("RuntimeError")
      expect(tc.failure_backtrace).to eq("full backtrace here")
      expect(result.error_count).to eq(1)
    end
  end

  describe "missing time attributes" do
    let(:xml) do
      <<~XML
        <testsuite name="NoTime">
          <testcase classname="NoTime" name="timeless"/>
        </testsuite>
      XML
    end

    it "returns nil duration for cases without time" do
      result = parse(xml)
      expect(result.cases.first.duration_ms).to be_nil
    end

    it "returns nil total duration when suite has no time" do
      result = parse(xml)
      expect(result.duration_ms).to be_nil
    end
  end

  describe "nested testsuites" do
    let(:xml) do
      <<~XML
        <testsuites>
          <testsuite name="Outer" time="0.2">
            <testsuite name="Inner" time="0.2">
              <testcase classname="Inner" name="nested" time="0.1"/>
            </testsuite>
          </testsuite>
        </testsuites>
      XML
    end

    it "does not error on nested suites (treats inner testsuite as opaque)" do
      expect { parse(xml) }.not_to raise_error
    end
  end

  describe "system-out and system-err capture" do
    let(:xml) do
      <<~XML
        <testsuite name="OutSpec" time="0.1">
          <testcase classname="OutSpec" name="chatty" time="0.1">
            <system-out>hello stdout</system-out>
            <system-err>hello stderr</system-err>
          </testcase>
        </testsuite>
      XML
    end

    it "combines system-out and system-err into output" do
      tc = parse(xml).cases.first
      expect(tc.output).to include("hello stdout")
      expect(tc.output).to include("hello stderr")
    end
  end

  describe "file attribute" do
    let(:xml) do
      <<~XML
        <testsuite name="FileSpec" time="0.1">
          <testcase classname="FileSpec" name="knows its file" file="spec/file_spec.rb" time="0.05"/>
        </testsuite>
      XML
    end

    it "captures file_path" do
      tc = parse(xml).cases.first
      expect(tc.file_path).to eq("spec/file_spec.rb")
    end
  end

  describe "malformed XML" do
    it "raises ParseError on invalid XML" do
      expect { parse("<broken") }.to raise_error(JunitXmlParser::ParseError)
    end

    it "raises ParseError on empty input" do
      expect { parse("") }.to raise_error(JunitXmlParser::ParseError)
    end

    it "raises ParseError on unexpected root element" do
      expect { parse("<results/>") }.to raise_error(JunitXmlParser::ParseError, /unexpected root element/)
    end
  end
end
