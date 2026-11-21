require "rails_helper"

# DOC-44 database boundary: a released WorkUnitLock must give up its unique
# `active_lock_key`, or its key stays taken forever and every later unit on
# that key waits behind a lock nobody holds. `WorkUnitLock#release!` clears
# both columns together. A write of `released_at` that skips the model
# (`update_all`, `update_column(s)`, `upsert`, `insert_all`) would not, so
# none may exist.
RSpec.describe "WorkUnitLock release" do
  def bulk_write
    /\b(?:update_all|update_columns?|upsert(?:_all)?|insert_all!?)\b/
  end

  it "never writes released_at around WorkUnitLock#release!" do
    offenders = Dir[Rails.root.join("{app,lib,plugins}/**/*.rb")].flat_map do |path|
      File.readlines(path).each_with_index.filter_map do |line, index|
        next unless line.include?("released_at") && line.match?(bulk_write)
        next if line.include?("active_lock_key")

        "#{Pathname.new(path).relative_path_from(Rails.root)}:#{index + 1}: #{line.strip}"
      end
    end

    expect(offenders).to be_empty, "release locks through WorkUnitLock#release!:\n#{offenders.join("\n")}"
  end
end
