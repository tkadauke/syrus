require "rails_helper"

RSpec.describe RepoCoveragePlan do
  def from_config(hash)
    described_class.from_config(hash)
  end

  describe ".from_config" do
    context "shorthand config (single artifact)" do
      it "parses to a single-source plan with lcov as the default format" do
        plan = from_config(
          "artifact" => "coverage/lcov.info",
          "threshold" => { "lines" => 80 },
          "on_miss" => "warn"
        )

        expect(plan.sources).to eq([ described_class::Source.new(artifact: "coverage/lcov.info", format: "lcov") ])
        expect(plan.on_miss).to eq("warn")
        expect(plan.threshold.lines).to eq(80.0)
      end

      it "accepts an explicit format override" do
        plan = from_config("artifact" => "coverage/cobertura.xml", "format" => "cobertura")

        expect(plan.sources.first.format).to eq("cobertura")
      end

      it "raises ConfigError when artifact is missing" do
        expect {
          from_config("on_miss" => "warn")
        }.to raise_error(SyrusYml::ConfigError, /artifact: is required/)
      end

      it "raises ConfigError when artifact is blank" do
        expect {
          from_config("artifact" => "  ")
        }.to raise_error(SyrusYml::ConfigError, /artifact: is required/)
      end
    end

    context "multi-source config" do
      it "parses multiple sources correctly" do
        plan = from_config(
          "sources" => [
            { "artifact" => "coverage/ruby/lcov.info", "format" => "lcov" },
            { "artifact" => "coverage/js/lcov.info", "format" => "lcov" }
          ],
          "threshold" => { "lines" => 80 },
          "on_miss" => "schedule",
          "schedule_prompt" => "Coverage fell below 80%.",
          "pr_comment" => true,
          "hitmap_ttl_days" => 14
        )

        expect(plan.sources).to eq([
          described_class::Source.new(artifact: "coverage/ruby/lcov.info", format: "lcov"),
          described_class::Source.new(artifact: "coverage/js/lcov.info", format: "lcov")
        ])
        expect(plan.on_miss).to eq("schedule")
        expect(plan.schedule_prompt).to eq("Coverage fell below 80%.")
        expect(plan.pr_comment).to be(true)
        expect(plan.hitmap_ttl_days).to eq(14)
        expect(plan.threshold.lines).to eq(80.0)
      end

      it "defaults format to lcov when omitted from a source entry" do
        plan = from_config("sources" => [ { "artifact" => "coverage/lcov.info" } ])

        expect(plan.sources.first.format).to eq("lcov")
      end

      it "raises ConfigError when sources is not an array" do
        expect {
          from_config("sources" => "coverage/lcov.info")
        }.to raise_error(SyrusYml::ConfigError, /sources: must be an array/)
      end

      it "raises ConfigError when sources array is empty" do
        expect {
          from_config("sources" => [])
        }.to raise_error(SyrusYml::ConfigError, /sources: must not be empty/)
      end

      it "raises ConfigError when a source entry is not a mapping" do
        expect {
          from_config("sources" => [ "coverage/lcov.info" ])
        }.to raise_error(SyrusYml::ConfigError, /sources\[0\]: must be a mapping/)
      end

      it "raises ConfigError when a source entry is missing artifact" do
        expect {
          from_config("sources" => [ { "format" => "lcov" } ])
        }.to raise_error(SyrusYml::ConfigError, /sources\[0\]\.artifact: is required/)
      end
    end

    context "defaults" do
      it "defaults on_miss to warn" do
        plan = from_config("artifact" => "coverage/lcov.info")
        expect(plan.on_miss).to eq("warn")
      end

      it "defaults pr_comment to true" do
        plan = from_config("artifact" => "coverage/lcov.info")
        expect(plan.pr_comment).to be(true)
      end

      it "defaults hitmap_ttl_days to 30" do
        plan = from_config("artifact" => "coverage/lcov.info")
        expect(plan.hitmap_ttl_days).to eq(30)
      end

      it "defaults threshold to nil" do
        plan = from_config("artifact" => "coverage/lcov.info")
        expect(plan.threshold).to be_nil
      end

      it "defaults schedule_prompt to nil" do
        plan = from_config("artifact" => "coverage/lcov.info")
        expect(plan.schedule_prompt).to be_nil
      end
    end

    context "on_miss validation" do
      %w[block warn].each do |value|
        it "accepts on_miss: #{value}" do
          plan = from_config("artifact" => "coverage/lcov.info", "on_miss" => value)
          expect(plan.on_miss).to eq(value)
        end
      end

      it "accepts on_miss: schedule when schedule_prompt is provided" do
        plan = from_config(
          "artifact" => "coverage/lcov.info",
          "on_miss" => "schedule",
          "schedule_prompt" => "Add tests to recently changed modules."
        )
        expect(plan.on_miss).to eq("schedule")
        expect(plan.schedule_prompt).to eq("Add tests to recently changed modules.")
      end

      it "raises ConfigError for an unknown on_miss value" do
        expect {
          from_config("artifact" => "coverage/lcov.info", "on_miss" => "ignore")
        }.to raise_error(SyrusYml::ConfigError, /on_miss.*not valid/)
      end

      it "raises ConfigError for on_miss: schedule without schedule_prompt" do
        expect {
          from_config("artifact" => "coverage/lcov.info", "on_miss" => "schedule")
        }.to raise_error(SyrusYml::ConfigError, /schedule_prompt: is required when on_miss is 'schedule'/)
      end
    end

    context "threshold parsing" do
      it "parses all threshold fields as floats" do
        plan = from_config(
          "artifact" => "coverage/lcov.info",
          "threshold" => { "lines" => 80, "branches" => 70, "pr_lines" => 90 }
        )

        expect(plan.threshold.lines).to eq(80.0)
        expect(plan.threshold.branches).to eq(70.0)
        expect(plan.threshold.pr_lines).to eq(90.0)
      end

      it "allows partial threshold (only lines configured)" do
        plan = from_config("artifact" => "coverage/lcov.info", "threshold" => { "lines" => 80 })

        expect(plan.threshold.lines).to eq(80.0)
        expect(plan.threshold.branches).to be_nil
        expect(plan.threshold.pr_lines).to be_nil
      end

      it "accepts floating-point threshold values" do
        plan = from_config("artifact" => "coverage/lcov.info", "threshold" => { "lines" => 79.5 })
        expect(plan.threshold.lines).to eq(79.5)
      end

      it "raises ConfigError when a threshold value is not a number" do
        expect {
          from_config("artifact" => "coverage/lcov.info", "threshold" => { "lines" => "high" })
        }.to raise_error(SyrusYml::ConfigError, /threshold\.lines: must be a number/)
      end

      it "raises ConfigError when threshold is not a mapping" do
        expect {
          from_config("artifact" => "coverage/lcov.info", "threshold" => 80)
        }.to raise_error(SyrusYml::ConfigError, /threshold: must be a mapping/)
      end
    end

    context "other validation" do
      it "raises ConfigError when given a non-mapping top-level value" do
        expect {
          from_config("coverage/lcov.info")
        }.to raise_error(SyrusYml::ConfigError, /must be a mapping/)
      end

      it "raises ConfigError when hitmap_ttl_days is not an integer" do
        expect {
          from_config("artifact" => "coverage/lcov.info", "hitmap_ttl_days" => "two weeks")
        }.to raise_error(SyrusYml::ConfigError, /hitmap_ttl_days: must be an integer/)
      end

      it "coerces pr_comment through Rails boolean semantics" do
        plan = from_config("artifact" => "coverage/lcov.info", "pr_comment" => "false")
        expect(plan.pr_comment).to be(false)
      end
    end
  end

  describe "#threshold_miss?" do
    let(:plan_with_threshold) do
      from_config(
        "artifact" => "coverage/lcov.info",
        "threshold" => { "lines" => 80, "pr_lines" => 90 }
      )
    end

    let(:plan_without_threshold) do
      from_config("artifact" => "coverage/lcov.info")
    end

    it "returns false when no threshold is configured" do
      expect(plan_without_threshold.threshold_miss?(lines_pct: 50)).to be(false)
    end

    it "returns false when lines coverage meets the threshold exactly" do
      expect(plan_with_threshold.threshold_miss?(lines_pct: 80)).to be(false)
    end

    it "returns false when lines coverage exceeds the threshold" do
      expect(plan_with_threshold.threshold_miss?(lines_pct: 95)).to be(false)
    end

    it "returns true when lines coverage falls below the threshold" do
      expect(plan_with_threshold.threshold_miss?(lines_pct: 79.9)).to be(true)
    end

    it "returns false when pr_delta_pct is nil and pr_lines threshold is configured" do
      expect(plan_with_threshold.threshold_miss?(lines_pct: 85, pr_delta_pct: nil)).to be(false)
    end

    it "returns true when pr_delta_pct falls below the pr_lines threshold" do
      expect(plan_with_threshold.threshold_miss?(lines_pct: 85, pr_delta_pct: 85)).to be(true)
    end

    it "returns false when pr_delta_pct meets the pr_lines threshold" do
      expect(plan_with_threshold.threshold_miss?(lines_pct: 85, pr_delta_pct: 90)).to be(false)
    end

    it "returns false when threshold has only branches configured (not checked by this method)" do
      plan = from_config(
        "artifact" => "coverage/lcov.info",
        "threshold" => { "branches" => 80 }
      )
      expect(plan.threshold_miss?(lines_pct: 10)).to be(false)
    end
  end
end
