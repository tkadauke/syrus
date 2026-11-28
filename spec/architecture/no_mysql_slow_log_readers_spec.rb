require "rails_helper"

RSpec.describe "MySQL diagnostics architecture" do
  it "does not read the table-backed slow-query log" do
    source_roots = %w[app lib plugins config]
    offenders = source_roots.flat_map do |root|
      Dir.glob(Rails.root.join(root, "**", "*.{rb,ts,tsx,js,md,json}")).filter_map do |path|
        path if File.read(path).match?(/FROM\s+mysql\.slow_log/i)
      end
    end

    expect(offenders).to be_empty, "table-backed slow-query-log readers found in: #{offenders.join(', ')}"
  end
end
