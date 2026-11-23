require "rails_helper"
require "tmpdir"

RSpec.describe SyrusCoverage::RepositoryConfiguration do
  around do |ex|
    Dir.mktmpdir("syrus-coverage-yml") { |dir| @dir = dir; ex.run }
  end

  def parse(contents)
    SyrusYml.new(contents).parse
  end

  def write_config(contents)
    File.write(File.join(@dir, ".syrus.yml"), contents)
  end

  def key = SyrusCoverage::RepositoryConfiguration::KEY

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

    plan = SyrusYml.load_repo(@dir).plugin_configurations[key]

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

  describe "coverage: key (legacy alias)" do
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

      cov = config.plugin_configurations[key]
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

      plan = SyrusYml.load_repo(@dir).plugin_configurations[key]

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

      expect(config.plugin_configurations[key].threshold.branches).to be_nil
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
      }.to raise_error(SyrusYml::ParseError, /coverage\.threshold\.branches: must be between 0 and 100/)
    end

    it "defaults on_miss to warn and hitmap_ttl_days to 7" do
      config = parse(<<~YAML)
        coverage:
          sources:
            - artifact: coverage/lcov.info
              format: lcov
      YAML

      expect(config.plugin_configurations[key].on_miss).to eq("warn")
      expect(config.plugin_configurations[key].hitmap_ttl_days).to eq(7)
    end

    it "returns nil for coverage when key is absent" do
      config = parse("grade:\n  - name: tests\n    run: bin/rspec\n")
      expect(config.plugin_configurations[key]).to be_nil
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
      }.to raise_error(SyrusYml::ParseError, /coverage\.on_miss: must be one of/)
    end

    it "rejects unknown coverage format" do
      expect {
        parse(<<~YAML)
          coverage:
            sources:
              - artifact: coverage/report.xml
                format: jacoco
        YAML
      }.to raise_error(SyrusYml::ParseError, /coverage\.sources\[0\]\.format: must be one of/)
    end

    it "rejects missing artifact path" do
      expect {
        parse(<<~YAML)
          coverage:
            sources:
              - format: lcov
        YAML
      }.to raise_error(SyrusYml::ParseError, /coverage\.sources\[0\]\.artifact: is required/)
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
      }.to raise_error(SyrusYml::ParseError, /coverage\.threshold\.lines: must be between 0 and 100/)
    end

    describe "Plan#threshold_miss?" do
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
        expect(config.plugin_configurations[key].threshold_miss?(lines_pct: 75.0)).to be true
      end

      it "returns true when pr_delta_pct is below pr_lines threshold" do
        expect(config.plugin_configurations[key].threshold_miss?(lines_pct: 85.0, pr_delta_pct: 60.0)).to be true
      end

      it "returns false when both are at or above threshold" do
        expect(config.plugin_configurations[key].threshold_miss?(lines_pct: 90.0, pr_delta_pct: 80.0)).to be false
      end

      it "returns false when pr_delta_pct is nil" do
        expect(config.plugin_configurations[key].threshold_miss?(lines_pct: 90.0, pr_delta_pct: nil)).to be false
      end
    end
  end

  it "accepts the native Go coverage profile format" do
    config = parse(<<~YAML)
      coverage:
        sources:
          - artifact: coverage.out
            format: go-cover
    YAML

    expect(config.plugin_configurations[key].sources.first.format).to eq("go-cover")
  end

  describe "namespaced envelope" do
    it "parses the same schema from plugins: { syrus_coverage.config: ... }" do
      config = parse(<<~YAML)
        plugins:
          syrus_coverage.config:
            version: 1
            config:
              sources:
                - artifact: coverage/lcov.info
                  format: lcov
              on_miss: block
      YAML

      expect(config.plugin_configurations[key].on_miss).to eq("block")
    end

    it "rejects an unsupported schema version" do
      expect {
        parse(<<~YAML)
          plugins:
            syrus_coverage.config:
              version: 9
              config:
                sources:
                  - artifact: coverage/lcov.info
                    format: lcov
        YAML
      }.to raise_error(SyrusYml::ParseError, /unsupported schema version/)
    end
  end

  describe "when the plugin is disabled" do
    before do
      PluginRecord.find_or_create_by!(name: "syrus_coverage").update!(enabled: false)
      Syrus::PluginRegistry.clear_plugin_record_cache!
    end

    after { Syrus::PluginRegistry.clear_plugin_record_cache! }

    it "does not parse the block and does not raise, even for an invalid one" do
      config = parse("coverage:\n  on_miss: panic\n")

      expect(config.plugin_configurations[key]).to be_nil
      expect(config.plugin_configurations.diagnostics.map(&:status)).to include("disabled")
    end
  end

  it "serializes a plan to canonical JSON" do
    config = parse(<<~YAML)
      coverage:
        sources:
          - artifact: coverage/lcov.info
            format: lcov
        threshold:
          lines: 80
    YAML

    serialized = config.plugin_configurations.contribution(key).serialized
    expect(serialized.fetch("sources")).to eq([ { "artifact" => "coverage/lcov.info", "format" => "lcov" } ])
    expect(serialized.fetch("threshold")).to include("lines" => 80.0)
    expect(serialized.fetch("on_miss")).to eq("warn")
  end
end
