require "rails_helper"

RSpec.describe "registered Job closure reasons" do
  it "does not pass unregistered string literals to Job closing methods" do
    files = Dir[Rails.root.join("{app,plugins}/**/*.rb")]
    calls = files.flat_map do |file|
      File.read(file).scan(/(?:close_with_reason!|cancel_active_runs_and_close!)\(\s*["']([^"']+)["']/).flatten
    end
    plugin_declarations = Dir[Rails.root.join("plugins/*/lib/**/*.rb")].flat_map do |file|
      File.read(file).scan(/closure_reasons:\s*\[(.*?)\]/m).flat_map do |body|
        body.first.scan(/\breason:\s*["']([^"']+)["']/).flatten
      end
    end

    expect(calls - Job::ClosureReason.values - plugin_declarations).to be_empty
  end
end
