require "rails_helper"

RSpec.describe "WorkUnit path ownership documentation" do
  CONTRACT_PATH = Rails.root.join("docs/engineering/architecture/work-unit-path-ownership.md")

  def matrix_paths
    in_matrix = false
    paths = []
    CONTRACT_PATH.each_line do |line|
      if line.start_with?("| Path |")
        in_matrix = true
        next
      end
      next unless in_matrix
      next if line.start_with?("| ---")
      break if line.blank? || !line.start_with?("|")

      paths << line.split("|")[1].delete("`").strip
    end
    paths
  end

  it "keeps documented paths in sync with executable path ownership" do
    documented = matrix_paths
    registered = WorkUnits::PathOwnership::PATH_GROUPS.keys.sort

    expect(documented.sort).to eq(registered), <<~MESSAGE
      docs/engineering/architecture/work-unit-path-ownership.md is the current
      contract for path ownership. Keep its table and WorkUnits::PathOwnership
      in sync so every documented path has a WorkUnit owner and every executable
      path has a stable ownership contract.
    MESSAGE
  end
end
