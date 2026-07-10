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

  it "parses post-checkout hooks" do
    config = parse(<<~YAML)
      hooks:
        post_checkout:
          - bundle exec rails db:migrate
          - bin/yarn install --frozen-lockfile
    YAML

    expect(config.hooks.post_checkout).to eq([
      "bundle exec rails db:migrate",
      "bin/yarn install --frozen-lockfile"
    ])
  end

  it "parses adversarial review rounds" do
    config = parse(<<~YAML)
      adversarial_review:
        rounds: 2
    YAML

    expect(config.adversarial_review.rounds).to eq(2)
  end

  it "clamps adversarial review rounds above the hard ceiling with a warning" do
    expect(Rails.logger).to receive(:warn).with(/adversarial_review\.rounds 12 outside 0\.\.10; clamping/)

    config = parse(<<~YAML)
      adversarial_review:
        rounds: 12
    YAML

    expect(config.adversarial_review.rounds).to eq(10)
  end

  it "rejects missing adversarial review rounds" do
    expect {
      parse(<<~YAML)
        adversarial_review: {}
      YAML
    }.to raise_error(described_class::ParseError, /adversarial_review\.rounds: is required/)
  end

  it "rejects non-integer adversarial review rounds" do
    expect {
      parse(<<~YAML)
        adversarial_review:
          rounds: many
      YAML
    }.to raise_error(described_class::ParseError, /adversarial_review\.rounds: must be an integer/)
  end

  it "rejects non-mapping hooks" do
    expect {
      parse(<<~YAML)
        hooks:
          - bundle exec rails db:migrate
      YAML
    }.to raise_error(described_class::ParseError, /hooks: must be a mapping/)
  end

  it "rejects non-array post-checkout hooks" do
    expect {
      parse(<<~YAML)
        hooks:
          post_checkout: bundle exec rails db:migrate
      YAML
    }.to raise_error(described_class::ParseError, /hooks\.post_checkout: must be an array of commands/)
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

  it "ConfigError is a subclass of ParseError" do
    expect(described_class::ConfigError.ancestors).to include(described_class::ParseError)
  end


  describe "coverage: key" do
    it "parses a full coverage block" do
      config = parse(<<~YAML)
        coverage:
          sources:
            - artifact: coverage/lcov.info
              format: lcov
          threshold:
            lines: 80
            pr_lines: 70
          on_miss: block
          hitmap_ttl_days: 14
          pr_comment: true
      YAML

      cov = config.coverage
      expect(cov.sources.size).to eq(1)
      expect(cov.sources.first.artifact).to eq("coverage/lcov.info")
      expect(cov.sources.first.format).to eq("lcov")
      expect(cov.threshold.lines).to eq(80.0)
      expect(cov.threshold.pr_lines).to eq(70.0)
      expect(cov.on_miss).to eq("block")
      expect(cov.hitmap_ttl_days).to eq(14)
      expect(cov.pr_comment).to be true
    end

    it "defaults on_miss to warn and hitmap_ttl_days to 7" do
      config = parse(<<~YAML)
        coverage:
          sources:
            - artifact: coverage/lcov.info
              format: lcov
      YAML

      expect(config.coverage.on_miss).to eq("warn")
      expect(config.coverage.hitmap_ttl_days).to eq(7)
    end

    it "returns nil for coverage when key is absent" do
      config = parse("grade:\n  - name: tests\n    run: bin/rspec\n")
      expect(config.coverage).to be_nil
    end

    it "rejects invalid on_miss value" do
      expect {
        parse(<<~YAML)
          coverage:
            sources:
              - artifact: coverage/lcov.info
                format: lcov
            on_miss: panic
        YAML
      }.to raise_error(described_class::ParseError, /coverage\.on_miss: must be one of/)
    end

    it "rejects unknown coverage format" do
      expect {
        parse(<<~YAML)
          coverage:
            sources:
              - artifact: coverage/report.xml
                format: jacoco
        YAML
      }.to raise_error(described_class::ParseError, /coverage\.sources\[0\]\.format: must be one of/)
    end

    it "rejects missing artifact path" do
      expect {
        parse(<<~YAML)
          coverage:
            sources:
              - format: lcov
        YAML
      }.to raise_error(described_class::ParseError, /coverage\.sources\[0\]\.artifact: is required/)
    end

    it "rejects threshold lines outside 0..100" do
      expect {
        parse(<<~YAML)
          coverage:
            sources:
              - artifact: coverage/lcov.info
                format: lcov
            threshold:
              lines: 110
        YAML
      }.to raise_error(described_class::ParseError, /coverage\.threshold\.lines: must be between 0 and 100/)
    end

    describe "CoverageConfig#threshold_miss?" do
      let(:config) do
        parse(<<~YAML)
          coverage:
            sources:
              - artifact: coverage/lcov.info
                format: lcov
            threshold:
              lines: 80
              pr_lines: 70
        YAML
      end

      it "returns true when lines_pct is below lines threshold" do
        expect(config.coverage.threshold_miss?(lines_pct: 75.0)).to be true
      end

      it "returns true when pr_delta_pct is below pr_lines threshold" do
        expect(config.coverage.threshold_miss?(lines_pct: 85.0, pr_delta_pct: 60.0)).to be true
      end

      it "returns false when both are at or above threshold" do
        expect(config.coverage.threshold_miss?(lines_pct: 90.0, pr_delta_pct: 80.0)).to be false
      end

      it "returns false when pr_delta_pct is nil" do
        expect(config.coverage.threshold_miss?(lines_pct: 90.0, pr_delta_pct: nil)).to be false
      end
    end
  end
end
