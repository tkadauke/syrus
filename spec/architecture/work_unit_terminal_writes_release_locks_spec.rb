require "rails_helper"

# A terminal WorkUnit must hold no active WorkUnitLock: an exclusive scope (a
# Job, an Epic, the repository landing slot) is held for exactly as long as
# the unit that took it is live. formal/SyrusModel/Proofs.lean
# `inv_no_terminal_locks` proves that for the modelled transitions, and the
# only two terminal writers in the model -- WorkUnit#mark_terminal! and
# WorkUnit#preempt! -- release the unit's active locks in the same transaction
# as the state write.
#
# The proof does not see writes that skip the model's transitions. This pins
# that there are none: no production code writes a WorkUnit's state with
# update_columns / update_column / update_all, which bypass both callbacks and
# the lock release. (The simulator's scenario loader builds fixtures and is
# exempt.)
RSpec.describe "WorkUnit terminal writes go through the lock-releasing transitions" do
  root = Rails.root
  sources = Dir[root.join("{app,lib,plugins/*/app,plugins/*/lib}/**/*.rb")].reject do |path|
    path.include?("/simulation/")
  end

  it "has no callback-skipping writes of WorkUnit state" do
    offenders = sources.flat_map do |path|
      File.readlines(path).each_with_index.filter_map do |line, index|
        next unless line.match?(/\b(?:unit|work_unit|units|work_units|WorkUnit[^\n]*)\b[^\n]*\.(?:update_columns|update_column|update_all)\b[^\n]*\bstate\b/)

        "#{path.delete_prefix("#{root}/")}:#{index + 1}: #{line.strip}"
      end
    end

    expect(offenders).to be_empty,
      "WorkUnit state must change through #mark_terminal! / #preempt! (which release the unit's locks):\n#{offenders.join("\n")}"
  end
end
