require "rails_helper"
require "tmpdir"

RSpec.describe SyrusYml do
  around do |ex|
    Dir.mktmpdir("syrus-yml") { |dir| @dir = dir; ex.run }
  end

  def parse(contents)
    described_class.new(contents).parse
  end

  def write_config(contents)
    File.write(File.join(@dir, ".syrus.yml"), contents)
  end

  it "parses the full grade form" do
    config = parse(<<~YAML)
      grade:
        max_iterations: 5
        steps:
          - name: tests
            run: bin/rspec
            required: true
          - name: lint
            run: bin/rubocop
            timeout_minutes: 5
    YAML

    expect(config.grade.max_iterations).to eq(5)
    expect(config.grade.steps).to eq([
      described_class::GradeStep.new(name: "tests", run: "bin/rspec", description: nil, required: true, timeout_minutes: 15),
      described_class::GradeStep.new(name: "lint", run: "bin/rubocop", description: nil, required: true, timeout_minutes: 5)
    ])
  end

  it "parses the bare grade array form using AppSetting.grade_max_iterations" do
    AppSetting.current.update!(grade_max_iterations: 7)

    config = parse(<<~YAML)
      grade:
        - name: tests
          run: bin/rspec
    YAML

    expect(config.grade.max_iterations).to eq(7)
    expect(config.grade.steps).to eq([
      described_class::GradeStep.new(name: "tests", run: "bin/rspec", description: nil, required: true, timeout_minutes: 15)
    ])
  end

  it "preserves prepare while parsing grade" do
    config = parse(<<~YAML)
      prepare:
        - bundle install
      grade:
        - name: tests
          run: bin/rspec
    YAML

    expect(config.prepare).to eq([ "bundle install" ])
    expect(config.grade.steps.first.name).to eq("tests")
  end

  it "loads .syrus.yml from a repository path" do
    write_config(<<~YAML)
      grade:
        - name: tests
          run: bin/rspec
    YAML

    expect(described_class.load_repo(@dir).grade.steps.first.run).to eq("bin/rspec")
  end

  it "defaults required to true and coerces advisory steps through Rails boolean semantics" do
    config = parse(<<~YAML)
      grade:
        - name: tests
          run: bin/rspec
          required: false
        - name: lint
          run: bin/rubocop
          required: "false"
    YAML

    expect(config.grade.steps.first.required).to be(false)
    expect(config.grade.steps.second.required).to be(false)
  end

  it "parses optional grader descriptions" do
    config = parse(<<~YAML)
      grade:
        - name: tests
          run: bin/rspec
          description: |
            Rejects regressions in the Rails suite.
    YAML

    expect(config.grade.steps.first.description).to eq("Rejects regressions in the Rails suite.")
  end

  it "clamps timeout_minutes above the hard ceiling with a warning" do
    expect(Rails.logger).to receive(:warn).with(/timeout_minutes 45 exceeds 30; clamping/)

    config = parse(<<~YAML)
      grade:
        - name: tests
          run: bin/rspec
          timeout_minutes: 45
    YAML

    expect(config.grade.steps.first.timeout_minutes).to eq(30)
  end

  it "clamps max_iterations below the lower bound with a warning" do
    expect(Rails.logger).to receive(:warn).with(/grade\.max_iterations 0 outside 1\.\.10; clamping/)

    config = parse(<<~YAML)
      grade:
        max_iterations: 0
        steps:
          - name: tests
            run: bin/rspec
    YAML

    expect(config.grade.max_iterations).to eq(1)
  end

  it "clamps max_iterations above the hard ceiling with a warning" do
    expect(Rails.logger).to receive(:warn).with(/grade\.max_iterations 12 outside 1\.\.10; clamping/)

    config = parse(<<~YAML)
      grade:
        max_iterations: 12
        steps:
          - name: tests
            run: bin/rspec
    YAML

    expect(config.grade.max_iterations).to eq(10)
  end

  it "rejects missing step names" do
    expect {
      parse(<<~YAML)
        grade:
          - run: bin/rspec
      YAML
    }.to raise_error(described_class::ParseError, /grade\.steps\[0\]\.name: is required/)
  end

  it "rejects duplicate step names" do
    expect {
      parse(<<~YAML)
        grade:
          - name: tests
            run: bin/rspec
          - name: tests
            run: bin/minitest
      YAML
    }.to raise_error(described_class::ParseError, /name: "tests" is duplicated/)
  end

  it "rejects names that are unsafe as path components" do
    expect {
      parse(<<~YAML)
        grade:
          - name: test/suite
            run: bin/rspec
      YAML
    }.to raise_error(described_class::ParseError, /must match/)
  end

  it "rejects missing run commands" do
    expect {
      parse(<<~YAML)
        grade:
          - name: tests
      YAML
    }.to raise_error(described_class::ParseError, /grade\.steps\[0\]\.run: is required/)
  end

  it "rejects non-array steps in full form" do
    expect {
      parse(<<~YAML)
        grade:
          steps: bin/rspec
      YAML
    }.to raise_error(described_class::ParseError, /grade\.steps: must be an array/)
  end

  it "rejects non-integer max_iterations" do
    expect {
      parse(<<~YAML)
        grade:
          max_iterations: many
          steps:
            - name: tests
              run: bin/rspec
      YAML
    }.to raise_error(described_class::ParseError, /grade\.max_iterations: must be an integer/)
  end
end
