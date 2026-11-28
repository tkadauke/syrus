require "rails_helper"

RSpec.describe "registered Job closure reasons" do
  it "does not pass unregistered string literals to Job closing methods" do
    files = Dir[Rails.root.join("{app,plugins}/**/*.rb")]
    calls = files.flat_map do |file|
      File.read(file).scan(/(?:close_with_reason!|cancel_active_runs_and_close!)\(\s*["']([^"']+)["']/).flatten
    end

    declared = Dir[Rails.root.join("plugins/*/lib/**/*.rb")].flat_map do |file|
      File.read(file).scan(/reason:\s*["']([^"']+)["']/).flatten
    end

    expect(calls - Job::ClosureReason.values - declared).to be_empty
  end
end
