require "rails_helper"

RSpec.describe "operational StepFailed problem declarations" do
  HIGH_VALUE_PATTERNS = [
    /agent didn't call submit_/,
    /required MCP tool/,
    /mcp_sidecar_failed/,
    /branch diverged/i,
    /rebuild required/,
    /No space left on device/,
    /Disk quota exceeded/,
    /no rollout found/,
    /No conversation found/
  ].freeze

  it "does not add high-value operational StepFailed messages without a Problem declaration" do
    offenders = Rails.root.glob("{app,plugins}*/**/*.rb").filter_map do |path|
      text = path.read
      next unless text.match?(/raise\s+(?:Steps::Base::)?StepFailed|StepFailed\.new/)

      text.each_line.with_index(1).filter_map do |line, line_number|
        next unless line.match?(/raise\s+(?:Steps::Base::)?StepFailed|StepFailed\.new/)
        next unless HIGH_VALUE_PATTERNS.any? { |pattern| line.match?(pattern) }
        next if line.include?("problem_code:") || line.include?("fail_with!")

        "#{path.relative_path_from(Rails.root)}:#{line_number}: #{line.strip}"
      end
    end.flatten

    expect(offenders).to be_empty, <<~MSG
      High-value operational StepFailed raise sites must declare a Problem with
      fail_with!(...) or problem_code:, so classifiers do not learn new Syrus-owned
      prose patterns:
      #{offenders.join("\n")}
    MSG
  end
end
