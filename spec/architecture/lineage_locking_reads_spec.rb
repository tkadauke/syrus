require "rails_helper"

# Lineage.lock! (and lock_all!, lock_subtree!, Job#lock_active_work!) collect
# a record's ancestry with plain reads before they wait on the row locks. Under
# MySQL's REPEATABLE READ those reads fix the transaction's snapshot, so a
# plain `reload` right after the lock answers with the rows as they were
# before a concurrent transaction committed -- the state the lock was taken to
# see. `with_lock`, which these locks replaced (NY40), re-read with a locking
# read; the re-read after a lineage lock must too (F149). A production grader
# fan-out Run executed twice through exactly this read.
RSpec.describe "re-reads after a lineage lock" do
  LINEAGE_LOCK = /Lineage\.lock(?:_all|_subtree)?!|lock_active_work!/
  PLAIN_RELOAD = /\.reload\b(?!\()/
  WINDOW = 3

  it "use locking reads" do
    offenders = Dir[Rails.root.join("{app,plugins/*/app}/**/*.rb")].flat_map do |path|
      lines = File.readlines(path)
      lines.each_index.select { |index| lines[index].match?(LINEAGE_LOCK) && !lines[index].lstrip.start_with?("#") }
           .flat_map do |index|
             (index + 1..[ index + WINDOW, lines.length - 1 ].min).filter_map do |follow|
               line = lines[follow]
               next if line.lstrip.start_with?("#")

               "#{Pathname.new(path).relative_path_from(Rails.root)}:#{follow + 1}: #{line.strip}" if line.match?(PLAIN_RELOAD)
             end
           end
    end

    expect(offenders).to be_empty, "Use reload(lock: true) after a lineage lock:\n#{offenders.join("\n")}"
  end
end
