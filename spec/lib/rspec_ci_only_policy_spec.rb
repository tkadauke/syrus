require "spec_helper"
require_relative "../../lib/rspec_ci_only_policy"

RSpec.describe RspecCiOnlyPolicy do
  describe ".include_ci_only?" do
    it "excludes ci_only specs when neither RUN_CI_ONLY_SPECS nor CI is set" do
      expect(described_class.include_ci_only?({})).to be false
    end

    it "includes ci_only specs when CI is set and RUN_CI_ONLY_SPECS is unset" do
      expect(described_class.include_ci_only?({ "CI" => "true" })).to be true
    end

    it "includes ci_only specs when RUN_CI_ONLY_SPECS=true, even without CI set" do
      expect(described_class.include_ci_only?({ "RUN_CI_ONLY_SPECS" => "true" })).to be true
    end

    it "excludes ci_only specs when RUN_CI_ONLY_SPECS=false, even when CI is set" do
      expect(described_class.include_ci_only?({ "CI" => "true", "RUN_CI_ONLY_SPECS" => "false" })).to be false
    end
  end
end
