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
      described_class::GradeStep.new(name: "tests", run: "bin/rspec", fast: nil, ci: nil, description: nil, required: true, timeout_minutes: 15, when_files_changed: nil, junit_output: nil),
      described_class::GradeStep.new(name: "lint", run: "bin/rubocop", fast: nil, ci: nil, description: nil, required: true, timeout_minutes: 5, when_files_changed: nil, junit_output: nil)
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
      described_class::GradeStep.new(name: "tests", run: "bin/rspec", fast: nil, ci: nil, description: nil, required: true, timeout_minutes: 15, when_files_changed: nil, junit_output: nil)
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

  it "parses an optional fast grader command" do
    config = parse(<<~YAML)
      grade:
        - name: rspec
          run: bin/rspec
          fast: COVERAGE=false bin/rspec
    YAML

    expect(config.grade.steps.first.run).to eq("bin/rspec")
    expect(config.grade.steps.first.fast).to eq("COVERAGE=false bin/rspec")
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

  it "clamps timeout_minutes above the hard ceiling with a warning" do
    expect(Rails.logger).to receive(:warn).with(/timeout_minutes 90 exceeds 60; clamping/)

    config = parse(<<~YAML)
      grade:
        - name: tests
          run: bin/rspec
          timeout_minutes: 90
    YAML

    expect(config.grade.steps.first.timeout_minutes).to eq(60)
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

    it "defaults to an empty array when absent" do
      expect(parse("grade: []").formatters).to eq([])
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

    it "defaults to an empty array when absent" do
      expect(parse("grade: []").generated).to eq([])
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

  describe "reconciliation_mode" do
    it "parses valid modes" do
      %w[pr feedback none].each do |mode|
        config = parse("reconciliation_mode: #{mode}\n")
        expect(config.reconciliation_mode).to eq(mode)
      end
    end

    it "returns nil when reconciliation_mode is absent" do
      config = parse("prepare: []\n")
      expect(config.reconciliation_mode).to be_nil
    end

    it "raises ParseError for an invalid reconciliation_mode" do
      expect { parse("reconciliation_mode: always\n") }
        .to raise_error(described_class::ParseError, /reconciliation_mode: must be one of/)
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
end
