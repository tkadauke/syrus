require "rails_helper"

RSpec.describe "work unit migration matrix" do
  PLAN_PATH = Rails.root.join("docs/plans/work-units-and-execution-resilience.md")

  def matrix_paths
    in_matrix = false
    paths = []
    PLAN_PATH.each_line do |line|
      if line.start_with?("| Path |")
        in_matrix = true
        next
      end
      next unless in_matrix
      next if line.start_with?("| ---")
      break if line.blank? || !line.start_with?("|")

      paths << line.split("|")[1].strip
    end
    paths
  end

  it "keeps documented migration paths in sync with executable path ownership" do
    documented = matrix_paths
    registered = WorkUnits::PathOwnership::PATH_GATES.keys.sort

    expect(documented.sort).to eq(registered), <<~MESSAGE
      docs/plans/work-units-and-execution-resilience.md is the migration
      contract for path ownership. Keep the matrix and WorkUnits::PathOwnership
      in sync so every documented path has a feature-gated owner and every
      executable path has graduation criteria.
    MESSAGE
  end
end
