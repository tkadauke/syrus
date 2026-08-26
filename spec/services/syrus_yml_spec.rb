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
    expect(config.grade.failures).to eq("strict")
    expect(config.grade.steps).to eq([
      described_class::GradeStep.new(name: "tests", run: "bin/rspec", ci: nil, phases: %w[review landing ci], description: nil, required: true, timeout_minutes: 15, when_files_changed: nil, junit_output: nil, failures: "strict"),
      described_class::GradeStep.new(name: "lint", run: "bin/rubocop", ci: nil, phases: %w[review landing ci], description: nil, required: true, timeout_minutes: 5, when_files_changed: nil, junit_output: nil, failures: "strict")
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
    expect(config.grade.failures).to eq("strict")
    expect(config.grade.steps).to eq([
      described_class::GradeStep.new(name: "tests", run: "bin/rspec", ci: nil, phases: %w[review landing ci], description: nil, required: true, timeout_minutes: 15, when_files_changed: nil, junit_output: nil, failures: "strict")
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

  it "parses adversarial_review criteria when present" do
    config = parse(<<~YAML)
      adversarial_review:
        rounds: 1
        criteria:
          - Verify all new endpoints enforce authentication
          - Check that database queries use parameterized inputs
    YAML

    expect(config.adversarial_review.criteria).to eq([
      "Verify all new endpoints enforce authentication",
      "Check that database queries use parameterized inputs"
    ])
  end

  it "defaults adversarial_review criteria to [] when absent" do
    config = parse(<<~YAML)
      adversarial_review:
        rounds: 1
    YAML

    expect(config.adversarial_review.criteria).to eq([])
  end

  it "accepts an empty adversarial_review criteria array" do
    config = parse(<<~YAML)
      adversarial_review:
        rounds: 1
        criteria: []
    YAML

    expect(config.adversarial_review.criteria).to eq([])
  end

  it "rejects a non-array adversarial_review criteria value" do
    expect {
      parse(<<~YAML)
        adversarial_review:
          rounds: 1
          criteria: "enforce auth"
      YAML
    }.to raise_error(described_class::ParseError, /adversarial_review\.criteria: must be an array of strings/)
  end

  it "strips blank entries from adversarial_review criteria" do
    config = parse(<<~YAML)
      adversarial_review:
        rounds: 1
        criteria:
          - Enforce authentication
          - "   "
          - ""
          - Check parameterized queries
    YAML

    expect(config.adversarial_review.criteria).to eq([
      "Enforce authentication",
      "Check parameterized queries"
    ])
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

  it "parses the two-source coverage config from the repo's own .syrus.yml" do
    write_config(<<~YAML)
      coverage:
        sources:
          - artifact: coverage/lcov.info
            format: lcov
          - artifact: coverage/js/lcov.info
            format: lcov
        threshold:
          lines: 70
        on_miss: warn
        pr_comment: true
        hitmap_ttl_days: 7
    YAML

    plan = described_class.load_repo(@dir).coverage

    expect(plan).not_to be_nil
    expect(plan.sources.size).to eq(2)
    expect(plan.sources[0].artifact).to eq("coverage/lcov.info")
    expect(plan.sources[0].format).to eq("lcov")
    expect(plan.sources[1].artifact).to eq("coverage/js/lcov.info")
    expect(plan.sources[1].format).to eq("lcov")
    expect(plan.threshold.lines).to eq(70.0)
    expect(plan.on_miss).to eq("warn")
    expect(plan.pr_comment).to be true
    expect(plan.hitmap_ttl_days).to eq(7)
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

  it "parses when_files_changed as an array of glob patterns" do
    config = parse(<<~YAML)
      grade:
        - name: website-build
          run: npm --prefix website run build
          when_files_changed:
            - "website/**"
            - "docs/**"
        - name: rspec
          run: bin/rspec
    YAML

    expect(config.grade.steps.first.when_files_changed).to eq(%w[website/** docs/**])
    expect(config.grade.steps.second.when_files_changed).to be_nil
  end

  it "parses an optional CI grader command" do
    config = parse(<<~YAML)
      grade:
        - name: rspec
          run: bin/rspec
          ci: RUN_CI_ONLY_SPECS=true bin/rspec
    YAML

    expect(config.grade.steps.first.run).to eq("bin/rspec")
    expect(config.grade.steps.first.ci).to eq("RUN_CI_ONLY_SPECS=true bin/rspec")
  end

  it "parses grader phases" do
    config = parse(<<~YAML)
      grade:
        - name: smoke
          run: bin/smoke
          phases: review
        - name: rspec
          run: bin/rspec
          phases: [landing, ci]
    YAML

    expect(config.grade.steps.first.phases).to eq(%w[review])
    expect(config.grade.steps.second.phases).to eq(%w[landing ci])
  end

  it "rejects unknown grader phases" do
    expect {
      parse(<<~YAML)
        grade:
          - name: tests
            run: bin/rspec
            phases: [review, production]
      YAML
    }.to raise_error(described_class::ParseError, /phases: must contain only review, landing, ci/)
  end

  it "returns nil for when_files_changed when the key is absent" do
    config = parse(<<~YAML)
      grade:
        - name: tests
          run: bin/rspec
    YAML

    expect(config.grade.steps.first.when_files_changed).to be_nil
  end

  it "rejects a non-array when_files_changed" do
    expect {
      parse(<<~YAML)
        grade:
          - name: website-build
            run: npm run build
            when_files_changed: "website/**"
      YAML
    }.to raise_error(described_class::ParseError, /when_files_changed: must be an array/)
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

  it "parses junit_output path when present" do
    config = parse(<<~YAML)
      grade:
        - name: tests
          run: bin/rspec
          junit_output: tmp/rspec-results.xml
    YAML

    expect(config.grade.steps.first.junit_output).to eq("tmp/rspec-results.xml")
  end

  it "defaults junit_output to nil when absent" do
    config = parse(<<~YAML)
      grade:
        - name: tests
          run: bin/rspec
    YAML

    expect(config.grade.steps.first.junit_output).to be_nil
  end

  it "parses grade-level failures as the default for steps" do
    config = parse(<<~YAML)
      grade:
        failures: allow_inherited
        steps:
          - name: tests
            run: bin/rspec
    YAML

    expect(config.grade.failures).to eq("allow_inherited")
    expect(config.grade.steps.first.failures).to eq("allow_inherited")
  end

  it "parses step-level failures overrides" do
    config = parse(<<~YAML)
      grade:
        failures: allow_inherited
        steps:
          - name: eager-load
            run: bin/check-eager-load
            failures: strict
    YAML

    expect(config.grade.steps.first.failures).to eq("strict")
  end

  it "rejects invalid failures policies" do
    expect {
      parse(<<~YAML)
        grade:
          - name: tests
            run: bin/rspec
            failures: sometimes
      YAML
    }.to raise_error(described_class::ParseError, /failures: must be one of/)
  end

  it "clamps timeout_minutes above the hard ceiling with a warning" do
    expect(Rails.logger).to receive(:warn).with(/timeout_minutes 120 exceeds 90; clamping/)

    config = parse(<<~YAML)
      grade:
        - name: tests
          run: bin/rspec
          timeout_minutes: 120
    YAML

    expect(config.grade.steps.first.timeout_minutes).to eq(90)
  end

  it "allows timeout_minutes up to the hard ceiling without clamping" do
    expect(Rails.logger).not_to receive(:warn)

    config = parse(<<~YAML)
      grade:
        - name: tests
          run: bin/rspec
          timeout_minutes: 90
    YAML

    expect(config.grade.steps.first.timeout_minutes).to eq(90)
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

    it "parses coverage.threshold.branches from the repo's own .syrus.yml" do
      write_config(<<~YAML)
        coverage:
          sources:
            - artifact: coverage/lcov.info
              format: lcov
          threshold:
            lines: 80
            branches: 65
            pr_lines: 70
      YAML

      plan = described_class.load_repo(@dir).coverage

      expect(plan.threshold.lines).to eq(80.0)
      expect(plan.threshold.branches).to eq(65.0)
      expect(plan.threshold.pr_lines).to eq(70.0)
    end

    it "defaults threshold.branches to nil when omitted" do
      config = parse(<<~YAML)
        coverage:
          sources:
            - artifact: coverage/lcov.info
              format: lcov
          threshold:
            lines: 80
      YAML

      expect(config.coverage.threshold.branches).to be_nil
    end

    it "rejects threshold branches outside 0..100" do
      expect {
        parse(<<~YAML)
          coverage:
            sources:
              - artifact: coverage/lcov.info
                format: lcov
            threshold:
              branches: 150
        YAML
      }.to raise_error(described_class::ParseError, /coverage\.threshold\.branches: must be between 0 and 100/)
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

  describe "formatters: key" do
    it "parses formatters, normalizing a string or array of file globs" do
      config = parse(<<~YAML)
        formatters:
          - command: bin/rubocop -a
            files: "**/*.rb"
          - command: npx prettier --write
            files:
              - "**/*.ts"
              - "**/*.tsx"
      YAML

      expect(config.formatters.size).to eq(2)
      expect(config.formatters.first.command).to eq("bin/rubocop -a")
      expect(config.formatters.first.files).to eq([ "**/*.rb" ])
      expect(config.formatters.last.files).to eq([ "**/*.ts", "**/*.tsx" ])
    end

    it "defaults to nil when absent (Steps::Format runs no formatting at all)" do
      expect(parse("grade: []").formatters).to be_nil
    end

    it "requires a command and files" do
      expect { parse("formatters:\n  - files: '**/*.rb'\n") }
        .to raise_error(SyrusYml::ParseError, /command: is required/)
      expect { parse("formatters:\n  - command: bin/rubocop -a\n") }
        .to raise_error(SyrusYml::ParseError, /files: is required/)
    end

    it "rejects a non-array formatters value" do
      expect { parse("formatters: bin/rubocop") }
        .to raise_error(SyrusYml::ParseError, /formatters: must be an array/)
    end

    it "parses false (or the YAML off spelling) as an explicit disable, distinct from absent" do
      expect(parse("formatters: false").formatters).to be(false)
      expect(parse("formatters: off").formatters).to be(false)
    end

    it "parses an explicit empty array as [], distinct from the nil used for an absent key" do
      expect(parse("formatters: []").formatters).to eq([])
    end
  end

  describe "generated: key" do
    it "parses generated entries with sources, generates, and codegen_ignore" do
      config = parse(<<~YAML)
        generated:
          - command: buf generate
            sources: "proto/**/*.proto"
            generates:
              - "lib/proto/**/*.rb"
          - command: bin/rails db:schema:dump
            generates: "db/schema.rb"
            codegen_ignore: true
      YAML

      expect(config.generated.size).to eq(2)
      buf = config.generated.first
      expect(buf.command).to eq("buf generate")
      expect(buf.sources).to eq([ "proto/**/*.proto" ])
      expect(buf.generates).to eq([ "lib/proto/**/*.rb" ])
      expect(buf.codegen_ignore).to be(false)

      schema = config.generated.last
      expect(schema.generates).to eq([ "db/schema.rb" ])
      expect(schema.sources).to eq([])
      expect(schema.codegen_ignore).to be(true)
    end

    it "defaults to nil when absent (Steps::Generate no-ops)" do
      expect(parse("grade: []").generated).to be_nil
    end

    it "parses false (or the YAML off spelling) as an explicit disable, distinct from absent" do
      expect(parse("generated: false").generated).to be(false)
      expect(parse("generated: off").generated).to be(false)
    end

    it "rejects a non-array generated value" do
      expect { parse("generated: buf generate") }
        .to raise_error(SyrusYml::ParseError, /generated: must be an array/)
    end

    it "requires command and generates but allows omitting sources" do
      expect { parse("generated:\n  - generates: 'x.rb'\n") }
        .to raise_error(SyrusYml::ParseError, /command: is required/)
      expect { parse("generated:\n  - command: buf generate\n") }
        .to raise_error(SyrusYml::ParseError, /generates: is required/)

      config = parse("generated:\n  - command: buf generate\n    generates: 'x.rb'\n")
      expect(config.generated.first.sources).to eq([])
    end

    it "coerces codegen_ignore through Rails boolean semantics" do
      config = parse(<<~YAML)
        generated:
          - command: gen
            generates: "x.rb"
            codegen_ignore: "yes"
      YAML

      expect(config.generated.first.codegen_ignore).to be(true)
    end
  end

  describe "agent_insight" do
    it "returns nil when absent" do
      config = parse("prepare: []\n")

      expect(config.agent_insight).to be_nil
    end

    it "parses prepare opt-in through Rails boolean semantics" do
      config = parse(<<~YAML)
        agent_insight:
          prepare: "yes"
      YAML

      expect(config.agent_insight.prepare).to be(true)
    end

    it "rejects a non-mapping value" do
      expect { parse("agent_insight: true\n") }
        .to raise_error(described_class::ParseError, /agent_insight: must be a mapping/)
    end
  end

  describe "review_plan" do
    it "defaults to false when absent" do
      config = parse("prepare: []\n")

      expect(config.review_plan).to be(false)
    end

    it "parses a bare boolean true" do
      config = parse("review_plan: true\n")

      expect(config.review_plan).to be(true)
    end

    it "parses a bare boolean false" do
      config = parse("review_plan: false\n")

      expect(config.review_plan).to be(false)
    end

    it "coerces through Rails boolean semantics" do
      config = parse("review_plan: \"yes\"\n")

      expect(config.review_plan).to be(true)
    end
  end

  describe "deployment_stages: key" do
    it "parses stages with a fixed tag" do
      config = parse(<<~YAML)
        deployment_stages:
          - name: staging
            tag: staging
          - name: production
            label: "In Production"
            tag: production
      YAML

      stages = config.deployment_stages
      expect(stages.size).to eq(2)
      expect(stages[0]).to eq(described_class::DeploymentStage.new(name: "staging", label: "Staging", tag: "staging", tag_pattern: nil))
      expect(stages[1]).to eq(described_class::DeploymentStage.new(name: "production", label: "In Production", tag: "production", tag_pattern: nil))
    end

    it "parses stages with a tag_pattern" do
      config = parse(<<~YAML)
        deployment_stages:
          - name: canary
            tag_pattern: "deploy-canary-*"
      YAML

      stage = config.deployment_stages.first
      expect(stage.tag_pattern).to eq("deploy-canary-*")
      expect(stage.tag).to be_nil
    end

    it "defaults label to titleized name when label is omitted" do
      config = parse(<<~YAML)
        deployment_stages:
          - name: pre_release
            tag: pre-release
      YAML

      expect(config.deployment_stages.first.label).to eq("Pre Release")
    end

    it "returns empty array when deployment_stages is absent" do
      config = parse("prepare: []\n")
      expect(config.deployment_stages).to eq([])
    end

    it "rejects a non-array deployment_stages value" do
      expect { parse("deployment_stages: staging\n") }
        .to raise_error(described_class::ParseError, /deployment_stages: must be an array/)
    end

    it "rejects a stage with missing name" do
      expect {
        parse(<<~YAML)
          deployment_stages:
            - tag: staging
        YAML
      }.to raise_error(described_class::ParseError, /deployment_stages\[0\]\.name: is required/)
    end

    it "rejects a name with invalid characters" do
      expect {
        parse(<<~YAML)
          deployment_stages:
            - name: my-stage
              tag: my-tag
        YAML
      }.to raise_error(described_class::ParseError, /deployment_stages\[0\]\.name: must contain only alphanumeric characters and underscores/)
    end

    it "rejects duplicate stage names" do
      expect {
        parse(<<~YAML)
          deployment_stages:
            - name: staging
              tag: staging
            - name: staging
              tag: staging-v2
        YAML
      }.to raise_error(described_class::ParseError, /"staging" is duplicated/)
    end

    it "rejects a stage with neither tag nor tag_pattern" do
      expect {
        parse(<<~YAML)
          deployment_stages:
            - name: staging
        YAML
      }.to raise_error(described_class::ParseError, /must specify either 'tag' or 'tag_pattern'/)
    end

    it "rejects a stage with both tag and tag_pattern" do
      expect {
        parse(<<~YAML)
          deployment_stages:
            - name: staging
              tag: staging
              tag_pattern: "deploy-staging-*"
        YAML
      }.to raise_error(described_class::ParseError, /cannot specify both 'tag' and 'tag_pattern'/)
    end

    it "rejects a non-mapping stage entry" do
      expect {
        parse(<<~YAML)
          deployment_stages:
            - staging
        YAML
      }.to raise_error(described_class::ParseError, /deployment_stages\[0\]: must be a mapping/)
    end

    it "parses the three stages declared in .syrus.yml for this repository" do
      config = parse(<<~YAML)
        deployment_stages:
          - name: staging
            label: "On Staging"
            tag: staging
          - name: production
            label: "In Production"
            tag: production
          - name: public
            label: "Released to Public"
            tag: release
      YAML

      stages = config.deployment_stages
      expect(stages.size).to eq(3)
      expect(stages[0]).to eq(described_class::DeploymentStage.new(name: "staging", label: "On Staging", tag: "staging", tag_pattern: nil))
      expect(stages[1]).to eq(described_class::DeploymentStage.new(name: "production", label: "In Production", tag: "production", tag_pattern: nil))
      expect(stages[2]).to eq(described_class::DeploymentStage.new(name: "public", label: "Released to Public", tag: "release", tag_pattern: nil))
    end
  end

  describe "preview: key" do
    it "parses a full preview block" do
      config = parse(<<~YAML)
        preview:
          start: "bin/rails server -p $PORT"
          setup:
            - "bundle install"
            - "npm ci"
          seed: "bin/rails db:seed"
          health_check: "/health"
          logs:
            - log/development.log
          env:
            RAILS_ENV: development
            DATABASE_URL: sqlite3:db/preview.sqlite3
          unset_env:
            - CACHE_DATABASE_URL
            - QUEUE_DATABASE_URL
      YAML

      expect(config.preview.start).to eq("bin/rails server -p $PORT")
      expect(config.preview.setup).to eq([ "bundle install", "npm ci" ])
      expect(config.preview.seed).to eq("bin/rails db:seed")
      expect(config.preview.health_check).to eq("/health")
      expect(config.preview.logs).to eq([ "log/development.log" ])
      expect(config.preview.env).to eq(
        "RAILS_ENV" => "development",
        "DATABASE_URL" => "sqlite3:db/preview.sqlite3"
      )
      expect(config.preview.unset_env).to eq(%w[ CACHE_DATABASE_URL QUEUE_DATABASE_URL ])
    end

    it "returns nil when preview key is absent" do
      expect(parse("grade: []").preview).to be_nil
    end

    it "defaults health_check to / when omitted" do
      config = parse(<<~YAML)
        preview:
          start: "node server.js"
      YAML

      expect(config.preview.health_check).to eq("/")
    end

    it "defaults setup, seed, and logs to []/nil/[] when omitted" do
      config = parse(<<~YAML)
        preview:
          start: "node server.js"
      YAML

      expect(config.preview.setup).to eq([])
      expect(config.preview.seed).to be_nil
      expect(config.preview.logs).to eq([])
      expect(config.preview.env).to eq({})
      expect(config.preview.unset_env).to eq([])
    end

    it "accepts a single unset_env string" do
      config = parse(<<~YAML)
        preview:
          start: "node server.js"
          unset_env: DATABASE_URL
      YAML

      expect(config.preview.unset_env).to eq([ "DATABASE_URL" ])
    end

    it "accepts a single setup string" do
      config = parse(<<~YAML)
        preview:
          start: "node server.js"
          setup: npm ci
      YAML

      expect(config.preview.setup).to eq([ "npm ci" ])
    end

    it "supports YAML aliases for sharing prepare commands with preview setup" do
      config = parse(<<~YAML)
        prepare: &prepare_commands
          - bundle install
        preview:
          setup: *prepare_commands
          start: "node server.js"
      YAML

      expect(config.prepare).to eq([ "bundle install" ])
      expect(config.preview.setup).to eq([ "bundle install" ])
    end

    it "rejects a non-array preview setup" do
      expect {
        parse("preview:\n  start: node server.js\n  setup:\n    command: npm ci\n")
      }.to raise_error(SyrusYml::ParseError, /preview\.setup/)
    end

    it "rejects a preview block with no start command" do
      expect {
        parse("preview:\n  seed: bin/seed\n")
      }.to raise_error(SyrusYml::ParseError, /preview\.start/)
    end

    it "rejects a non-mapping preview value" do
      expect {
        parse("preview: true\n")
      }.to raise_error(SyrusYml::ParseError, /preview.*mapping/)
    end

    it "rejects a non-mapping preview env" do
      expect {
        parse("preview:\n  start: node server.js\n  env: []\n")
      }.to raise_error(SyrusYml::ParseError, /preview\.env.*mapping/)
    end

    it "rejects a non-array preview unset_env" do
      expect {
        parse("preview:\n  start: node server.js\n  unset_env:\n    DATABASE_URL: true\n")
      }.to raise_error(SyrusYml::ParseError, /preview\.unset_env/)
    end
  end

  describe "visual_review: key" do
    it "returns nil when visual_review key is absent" do
      expect(parse("grade: []").visual_review).to be_nil
    end

    it "parses a full visual_review block" do
      config = parse(<<~YAML)
        visual_review:
          enabled: true
          rounds: 2
          when_files_changed:
            - "app/frontend/**/*"
            - "app/views/**/*"
          seed_notes: "Log in as demo@example.com / password to reach the dashboard."
      YAML

      expect(config.visual_review.enabled).to be true
      expect(config.visual_review.rounds).to eq(2)
      expect(config.visual_review.when_files_changed).to eq([
        "app/frontend/**/*",
        "app/views/**/*"
      ])
      expect(config.visual_review.seed_notes).to eq("Log in as demo@example.com / password to reach the dashboard.")
    end

    it "defaults enabled to nil (defers to the instance-wide Feature default), rounds to 1, when_files_changed to nil, and seed_notes to nil when omitted" do
      config = parse(<<~YAML)
        visual_review: {}
      YAML

      expect(config.visual_review.enabled).to be_nil
      expect(config.visual_review.rounds).to eq(1)
      expect(config.visual_review.when_files_changed).to be_nil
      expect(config.visual_review.seed_notes).to be_nil
    end

    it "leaves enabled nil when the block is present but the enabled key is omitted, even with other keys set" do
      config = parse(<<~YAML)
        visual_review:
          rounds: 2
          seed_notes: "Log in as demo@example.com / password."
      YAML

      expect(config.visual_review.enabled).to be_nil
      expect(config.visual_review.rounds).to eq(2)
    end

    it "records an explicit enabled: false repo override distinctly from an omitted key" do
      config = parse(<<~YAML)
        visual_review:
          enabled: false
      YAML

      expect(config.visual_review.enabled).to be false
    end

    it "casts an unrecognized non-boolean enabled value to true, not nil" do
      config = parse(<<~YAML)
        visual_review:
          enabled: maybe
      YAML

      expect(config.visual_review.enabled).to be true
    end

    it "clamps visual_review rounds above the hard ceiling with a warning" do
      expect(Rails.logger).to receive(:warn).with(/visual_review\.rounds 12 outside 0\.\.10; clamping/)

      config = parse(<<~YAML)
        visual_review:
          enabled: true
          rounds: 12
      YAML

      expect(config.visual_review.rounds).to eq(10)
    end

    it "clamps negative visual_review rounds with a warning" do
      expect(Rails.logger).to receive(:warn).with(/visual_review\.rounds -1 outside 0\.\.10; clamping/)

      config = parse(<<~YAML)
        visual_review:
          rounds: -1
      YAML

      expect(config.visual_review.rounds).to eq(0)
    end

    it "rejects non-integer visual_review rounds" do
      expect {
        parse(<<~YAML)
          visual_review:
            rounds: many
        YAML
      }.to raise_error(SyrusYml::ParseError, /visual_review\.rounds: must be an integer/)
    end

    it "rejects a non-mapping visual_review value" do
      expect {
        parse("visual_review: true\n")
      }.to raise_error(SyrusYml::ParseError, /visual_review: must be a mapping/)
    end

    it "rejects a non-array visual_review when_files_changed" do
      expect {
        parse("visual_review:\n  when_files_changed: \"app/frontend/**/*\"\n")
      }.to raise_error(SyrusYml::ParseError, /visual_review\.when_files_changed: must be an array/)
    end

    it "strips blank entries from visual_review when_files_changed" do
      config = parse(<<~YAML)
        visual_review:
          when_files_changed:
            - "app/frontend/**/*"
            - "   "
            - ""
      YAML

      expect(config.visual_review.when_files_changed).to eq([ "app/frontend/**/*" ])
    end

    it "treats a blank seed_notes as nil" do
      config = parse(<<~YAML)
        visual_review:
          seed_notes: "   "
      YAML

      expect(config.visual_review.seed_notes).to be_nil
    end
  end

  describe "deploy: key" do
    it "returns nil when deploy key is absent" do
      expect(parse("grade: []").deploy).to be_nil
    end

    it "parses a full deploy block" do
      config = parse(<<~YAML)
        deploy:
          mode: continuous
          run: bin/deploy
          allow_unapproved: true
          min_interval_minutes: 15
      YAML

      expect(config.deploy.mode).to eq("continuous")
      expect(config.deploy.run).to eq("bin/deploy")
      expect(config.deploy.allow_unapproved).to eq(true)
      expect(config.deploy.min_interval_minutes).to eq(15)
    end

    it "defaults mode to manual, allow_unapproved to false, and min_interval_minutes to nil" do
      config = parse(<<~YAML)
        deploy:
          run: bin/deploy
      YAML

      expect(config.deploy.mode).to eq("manual")
      expect(config.deploy.allow_unapproved).to eq(false)
      expect(config.deploy.min_interval_minutes).to be_nil
    end

    it "rejects a non-mapping deploy value" do
      expect {
        parse("deploy: true\n")
      }.to raise_error(SyrusYml::ParseError, /deploy.*mapping/)
    end

    it "rejects a deploy block with no run command" do
      expect {
        parse("deploy:\n  mode: manual\n")
      }.to raise_error(SyrusYml::ParseError, /deploy\.run: is required/)
    end

    it "rejects a blank run command" do
      expect {
        parse("deploy:\n  run: \"   \"\n")
      }.to raise_error(SyrusYml::ParseError, /deploy\.run: is required/)
    end

    it "rejects an invalid mode" do
      expect {
        parse("deploy:\n  run: bin/deploy\n  mode: eventually\n")
      }.to raise_error(SyrusYml::ParseError, /deploy\.mode: must be one of manual, continuous/)
    end

    it "accepts mode: manual explicitly" do
      config = parse("deploy:\n  run: bin/deploy\n  mode: manual\n")

      expect(config.deploy.mode).to eq("manual")
    end

    it "rejects a non-positive min_interval_minutes" do
      expect {
        parse("deploy:\n  run: bin/deploy\n  min_interval_minutes: 0\n")
      }.to raise_error(SyrusYml::ParseError, /deploy\.min_interval_minutes: must be a positive integer/)
    end

    it "rejects a negative min_interval_minutes" do
      expect {
        parse("deploy:\n  run: bin/deploy\n  min_interval_minutes: -5\n")
      }.to raise_error(SyrusYml::ParseError, /deploy\.min_interval_minutes: must be a positive integer/)
    end

    it "rejects a non-integer min_interval_minutes" do
      expect {
        parse("deploy:\n  run: bin/deploy\n  min_interval_minutes: soon\n")
      }.to raise_error(SyrusYml::ParseError, /deploy\.min_interval_minutes: must be a positive integer/)
    end
  end

  describe "delivery: key" do
    describe "backward-compatible default (no delivery: section)" do
      it "normalizes to one default track with no explicit branch, review/landing/ci/ci grade phases, and everything else disabled" do
        config = parse("grade: []")

        expect(config.raw_delivery).to be_nil
        expect(config.delivery.tracks.keys).to eq([ "default" ])

        default_track = config.delivery.tracks.fetch("default")
        expect(default_track.name).to eq("default")
        expect(default_track.branch).to be_nil
        expect(default_track.review_grade_phase).to eq("review")
        expect(default_track.landing_grade_phase).to eq("landing")
        expect(default_track.ci_failure_grade_phase).to eq("ci")
        expect(default_track.branch_health_grade_phase).to eq("ci")
        expect(default_track.after_landing_sync_to).to be_nil

        expect(config.delivery.promotion.enabled).to be(false)
        expect(config.delivery.hotfix_sync.enabled).to be(false)
        expect(config.delivery.upstream_export.enabled).to be(false)
        expect(config.delivery.ref_movement_actions).to eq({})
      end
    end

    describe "tracks" do
      it "parses an explicit tracks block, defaulting omitted grade phases" do
        config = parse(<<~YAML)
          delivery:
            tracks:
              default:
                branch: develop
                grade_phases:
                  review: review_minimal
                  landing: landing_minimal
              hotfix:
                branch: main
                grade_phases:
                  review: review_minimal
                  landing: promotion
                after_landing:
                  sync_to: default
        YAML

        expect(config.raw_delivery.tracks.keys).to eq(%w[default hotfix])

        default_track = config.delivery.tracks.fetch("default")
        expect(default_track.branch).to eq("develop")
        expect(default_track.review_grade_phase).to eq("review_minimal")
        expect(default_track.landing_grade_phase).to eq("landing_minimal")
        expect(default_track.ci_failure_grade_phase).to eq("ci")
        expect(default_track.branch_health_grade_phase).to eq("ci")

        hotfix_track = config.delivery.tracks.fetch("hotfix")
        expect(hotfix_track.branch).to eq("main")
        expect(hotfix_track.landing_grade_phase).to eq("promotion")
        expect(hotfix_track.after_landing_sync_to).to eq("default")
      end

      it "requires a delivery: section's explicit tracks to include a default track" do
        expect {
          parse("delivery:\n  tracks:\n    hotfix:\n      branch: main\n")
        }.to raise_error(SyrusYml::ParseError, /delivery\.tracks: must include a "default" track/)
      end

      it "rejects a non-mapping tracks value" do
        expect {
          parse("delivery:\n  tracks: nope\n")
        }.to raise_error(SyrusYml::ParseError, /delivery\.tracks: must be a mapping/)
      end

      it "rejects a non-mapping track entry" do
        expect {
          parse("delivery:\n  tracks:\n    default: nope\n")
        }.to raise_error(SyrusYml::ParseError, /delivery\.tracks\.default: must be a mapping/)
      end

      it "rejects a track name with invalid characters" do
        expect {
          parse("delivery:\n  tracks:\n    \"bad name\":\n      branch: main\n    default:\n      branch: main\n")
        }.to raise_error(SyrusYml::ParseError, /name must match/)
      end

      it "rejects a non-mapping grade_phases value" do
        expect {
          parse("delivery:\n  tracks:\n    default:\n      grade_phases: nope\n")
        }.to raise_error(SyrusYml::ParseError, /delivery\.tracks\.default\.grade_phases: must be a mapping/)
      end

      it "rejects a non-mapping after_landing value" do
        expect {
          parse("delivery:\n  tracks:\n    default:\n      after_landing: nope\n")
        }.to raise_error(SyrusYml::ParseError, /delivery\.tracks\.default\.after_landing: must be a mapping/)
      end

      it "defaults a track's branch to nil when omitted, for DeliveryPolicy to resolve from the repository" do
        config = parse("delivery:\n  tracks:\n    default: {}\n")

        expect(config.delivery.tracks.fetch("default").branch).to be_nil
      end
    end

    describe "promotion" do
      it "parses a full promotion block" do
        config = parse(<<~YAML)
          delivery:
            promotion:
              enabled: true
              mode: auto_pr
              approval_required: false
              grade_phases: [promotion]
              repair_skill: integrate_release_branch
        YAML

        expect(config.delivery.promotion.enabled).to be(true)
        expect(config.delivery.promotion.mode).to eq("auto_pr")
        expect(config.delivery.promotion.approval_required).to be(false)
        expect(config.delivery.promotion.grade_phases).to eq([ "promotion" ])
        expect(config.delivery.promotion.repair_skill).to eq("integrate_release_branch")
      end

      it "defaults mode to auto_pr and enabled/approval_required to false" do
        config = parse("delivery:\n  promotion: {}\n")

        expect(config.delivery.promotion.enabled).to be(false)
        expect(config.delivery.promotion.mode).to eq("auto_pr")
        expect(config.delivery.promotion.approval_required).to be(false)
        expect(config.delivery.promotion.grade_phases).to eq([])
      end

      it "accepts a single grade_phases string" do
        config = parse("delivery:\n  promotion:\n    grade_phases: promotion\n")

        expect(config.delivery.promotion.grade_phases).to eq([ "promotion" ])
      end

      it "rejects a non-mapping promotion value" do
        expect {
          parse("delivery:\n  promotion: true\n")
        }.to raise_error(SyrusYml::ParseError, /delivery\.promotion: must be a mapping/)
      end

      it "rejects an invalid promotion mode" do
        expect {
          parse("delivery:\n  promotion:\n    mode: whenever\n")
        }.to raise_error(SyrusYml::ParseError, /delivery\.promotion\.mode: must be one of direct, auto_pr, manual_pr/)
      end
    end

    describe "hotfix_sync" do
      it "parses a full hotfix_sync block" do
        config = parse(<<~YAML)
          delivery:
            hotfix_sync:
              enabled: true
              direction: release_to_development
              mode: auto
              grade_phases: [promotion]
              repair_skill: backport_release_hotfix
        YAML

        expect(config.delivery.hotfix_sync.enabled).to be(true)
        expect(config.delivery.hotfix_sync.direction).to eq("release_to_development")
        expect(config.delivery.hotfix_sync.mode).to eq("auto")
        expect(config.delivery.hotfix_sync.grade_phases).to eq([ "promotion" ])
        expect(config.delivery.hotfix_sync.repair_skill).to eq("backport_release_hotfix")
      end

      it "defaults direction to release_to_development and mode to auto" do
        config = parse("delivery:\n  hotfix_sync:\n    enabled: true\n")

        expect(config.delivery.hotfix_sync.direction).to eq("release_to_development")
        expect(config.delivery.hotfix_sync.mode).to eq("auto")
      end

      it "rejects a non-mapping hotfix_sync value" do
        expect {
          parse("delivery:\n  hotfix_sync: true\n")
        }.to raise_error(SyrusYml::ParseError, /delivery\.hotfix_sync: must be a mapping/)
      end

      it "rejects an invalid direction" do
        expect {
          parse("delivery:\n  hotfix_sync:\n    direction: sideways\n")
        }.to raise_error(SyrusYml::ParseError, /delivery\.hotfix_sync\.direction: must be one of release_to_development/)
      end

      it "rejects an invalid mode" do
        expect {
          parse("delivery:\n  hotfix_sync:\n    mode: whenever\n")
        }.to raise_error(SyrusYml::ParseError, /delivery\.hotfix_sync\.mode: must be one of auto, auto_pr, manual_pr/)
      end
    end

    describe "upstream_export" do
      it "parses a full upstream_export block" do
        config = parse(<<~YAML)
          delivery:
            upstream_export:
              enabled: true
              mode: per_job_pr
              after_local_approval: true
              target: upstream_intake
        YAML

        expect(config.delivery.upstream_export.enabled).to be(true)
        expect(config.delivery.upstream_export.mode).to eq("per_job_pr")
        expect(config.delivery.upstream_export.after_local_approval).to be(true)
        expect(config.delivery.upstream_export.target).to eq("upstream_intake")
      end

      it "defaults mode to per_job_pr and after_local_approval to true" do
        config = parse("delivery:\n  upstream_export:\n    enabled: true\n")

        expect(config.delivery.upstream_export.mode).to eq("per_job_pr")
        expect(config.delivery.upstream_export.after_local_approval).to be(true)
      end

      it "rejects a non-mapping upstream_export value" do
        expect {
          parse("delivery:\n  upstream_export: true\n")
        }.to raise_error(SyrusYml::ParseError, /delivery\.upstream_export: must be a mapping/)
      end

      it "rejects an invalid mode" do
        expect {
          parse("delivery:\n  upstream_export:\n    mode: telepathy\n")
        }.to raise_error(SyrusYml::ParseError, /delivery\.upstream_export\.mode: must be one of per_job_pr, branch_pr/)
      end
    end

    describe "ref_movement_actions" do
      it "parses a full ref_movement_actions block" do
        config = parse(<<~YAML)
          delivery:
            ref_movement_actions:
              send_job_upstream:
                enabled: true
                source: { kind: job_branch }
                target: { kind: upstream_intake }
                mode: manual_pr
                grade_phases: [promotion]
              promote_development:
                enabled: true
                source: { kind: track, name: default }
                target: { kind: branch, name: main }
                mode: auto_pr
        YAML

        actions = config.delivery.ref_movement_actions
        expect(actions.keys).to eq(%w[send_job_upstream promote_development])

        send_job_upstream = actions.fetch("send_job_upstream")
        expect(send_job_upstream.enabled).to be(true)
        expect(send_job_upstream.source).to eq(described_class::DeliveryRefEndpoint.new(kind: "job_branch", name: nil))
        expect(send_job_upstream.target).to eq(described_class::DeliveryRefEndpoint.new(kind: "upstream_intake", name: nil))
        expect(send_job_upstream.mode).to eq("manual_pr")
        expect(send_job_upstream.grade_phases).to eq([ "promotion" ])

        promote_development = actions.fetch("promote_development")
        expect(promote_development.source).to eq(described_class::DeliveryRefEndpoint.new(kind: "track", name: "default"))
        expect(promote_development.target).to eq(described_class::DeliveryRefEndpoint.new(kind: "branch", name: "main"))
      end

      it "defaults enabled to false when omitted" do
        config = parse(<<~YAML)
          delivery:
            ref_movement_actions:
              send_job_upstream:
                source: { kind: job_branch }
                target: { kind: upstream_intake }
                mode: manual_pr
        YAML

        expect(config.delivery.ref_movement_actions.fetch("send_job_upstream").enabled).to be(false)
      end

      it "rejects a non-mapping ref_movement_actions value" do
        expect {
          parse("delivery:\n  ref_movement_actions: nope\n")
        }.to raise_error(SyrusYml::ParseError, /delivery\.ref_movement_actions: must be a mapping/)
      end

      it "rejects an action missing mode" do
        expect {
          parse(<<~YAML)
            delivery:
              ref_movement_actions:
                send_job_upstream:
                  source: { kind: job_branch }
                  target: { kind: upstream_intake }
          YAML
        }.to raise_error(SyrusYml::ParseError, /send_job_upstream\.mode: is required/)
      end

      it "rejects an action with an invalid mode" do
        expect {
          parse(<<~YAML)
            delivery:
              ref_movement_actions:
                send_job_upstream:
                  source: { kind: job_branch }
                  target: { kind: upstream_intake }
                  mode: telepathically
          YAML
        }.to raise_error(SyrusYml::ParseError, /send_job_upstream\.mode: must be one of direct, auto_pr, manual_pr/)
      end

      it "rejects an action missing a source" do
        expect {
          parse(<<~YAML)
            delivery:
              ref_movement_actions:
                send_job_upstream:
                  target: { kind: upstream_intake }
                  mode: manual_pr
          YAML
        }.to raise_error(SyrusYml::ParseError, /send_job_upstream\.source: is required/)
      end

      it "rejects a source/target missing a kind" do
        expect {
          parse(<<~YAML)
            delivery:
              ref_movement_actions:
                send_job_upstream:
                  source: { name: default }
                  target: { kind: upstream_intake }
                  mode: manual_pr
          YAML
        }.to raise_error(SyrusYml::ParseError, /send_job_upstream\.source\.kind: is required/)
      end
    end

    it "rejects a non-mapping delivery value" do
      expect {
        parse("delivery: true\n")
      }.to raise_error(SyrusYml::ParseError, /delivery: must be a mapping/)
    end

    it "parses the full Story 2 example from the delivery tracks plan" do
      config = parse(<<~YAML)
        delivery:
          tracks:
            default:
              branch: develop
              grade_phases:
                review: review_minimal
                landing: landing_minimal
            hotfix:
              branch: main
              grade_phases:
                review: review_minimal
                landing: promotion
              after_landing:
                sync_to: default

          promotion:
            enabled: true
            mode: auto_pr
            approval_required: false
            repair_skill: integrate_release_branch

          hotfix_sync:
            enabled: true
            direction: release_to_development
            mode: auto
            repair_skill: backport_release_hotfix
      YAML

      expect(config.delivery.tracks.keys).to eq(%w[default hotfix])
      expect(config.delivery.promotion.enabled).to be(true)
      expect(config.delivery.hotfix_sync.enabled).to be(true)
      expect(config.delivery.upstream_export.enabled).to be(false)
      expect(config.delivery.ref_movement_actions).to eq({})
    end
  end

  describe "approval: key" do
    it "returns nil when the approval key is absent -- use current approval behavior" do
      expect(parse("grade: []").approval).to be_nil
    end

    it "parses approval.job.required.owner" do
      config = parse(<<~YAML)
        approval:
          job:
            required:
              owner: true
      YAML

      expect(config.approval.job.owner_required).to be(true)
      expect(config.approval.job.peer_count).to be_nil
      expect(config.approval.promotion).to be_nil
    end

    it "parses approval.job.required.owner and peer_count together" do
      config = parse(<<~YAML)
        approval:
          job:
            required:
              owner: true
              peer_count: 1
      YAML

      expect(config.approval.job.owner_required).to be(true)
      expect(config.approval.job.peer_count).to eq(1)
    end

    it "parses approval.promotion.required.maintainer_count" do
      config = parse(<<~YAML)
        approval:
          job:
            required:
              owner: true
              peer_count: 1
          promotion:
            required:
              maintainer_count: 1
      YAML

      expect(config.approval.promotion.maintainer_count).to eq(1)
    end

    it "leaves owner_required nil when approval.job has no required.owner key" do
      config = parse(<<~YAML)
        approval:
          job:
            required:
              peer_count: 2
      YAML

      expect(config.approval.job.owner_required).to be_nil
      expect(config.approval.job.peer_count).to eq(2)
    end

    it "leaves job and promotion nil when approval: is an empty mapping" do
      config = parse("approval: {}\n")

      expect(config.approval.job).to be_nil
      expect(config.approval.promotion).to be_nil
    end

    it "rejects a non-mapping approval value" do
      expect {
        parse("approval: true\n")
      }.to raise_error(SyrusYml::ParseError, /approval: must be a mapping/)
    end

    it "rejects a non-mapping approval.job value" do
      expect {
        parse("approval:\n  job: true\n")
      }.to raise_error(SyrusYml::ParseError, /approval\.job: must be a mapping/)
    end

    it "rejects a non-mapping approval.job.required value" do
      expect {
        parse("approval:\n  job:\n    required: true\n")
      }.to raise_error(SyrusYml::ParseError, /approval\.job\.required: must be a mapping/)
    end

    it "rejects a negative peer_count" do
      expect {
        parse("approval:\n  job:\n    required:\n      peer_count: -1\n")
      }.to raise_error(SyrusYml::ParseError, /approval\.job\.required\.peer_count: must not be negative/)
    end

    it "rejects a non-integer peer_count" do
      expect {
        parse("approval:\n  job:\n    required:\n      peer_count: soon\n")
      }.to raise_error(SyrusYml::ParseError, /approval\.job\.required\.peer_count: must be an integer/)
    end

    it "rejects a non-mapping approval.promotion value" do
      expect {
        parse("approval:\n  promotion: true\n")
      }.to raise_error(SyrusYml::ParseError, /approval\.promotion: must be a mapping/)
    end

    it "rejects a negative maintainer_count" do
      expect {
        parse("approval:\n  promotion:\n    required:\n      maintainer_count: -1\n")
      }.to raise_error(SyrusYml::ParseError, /approval\.promotion\.required\.maintainer_count: must not be negative/)
    end
  end
end
