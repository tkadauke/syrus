require "rails_helper"

# Rails keeps only the last commit callback registered under a method name:
#
#   after_create_commit :publish_upserted
#   after_update_commit :publish_upserted   # replaces the create one
#
# leaves creates silent. That shipped three times (Job and Epic never
# announced new records, JobDependency never rechecked start blocks on save).
# One `after_commit :method, on: %i[create update]` declaration says the same
# thing and works.
RSpec.describe "commit callbacks" do
  it "register each method under one commit callback" do
    pattern = /^\s*after_(create|update|destroy|save)_commit\s+:(\w+[!?]?)/
    offenders = Dir.glob(Rails.root.join("{app,plugins/*/app}/models/**/*.rb")).flat_map do |file|
      relative = Pathname(file).relative_path_from(Rails.root).to_s
      registrations = Hash.new { |hash, key| hash[key] = [] }
      File.readlines(file).each_with_index do |line, index|
        next unless (match = line.match(pattern))

        registrations[match[2]] << "after_#{match[1]}_commit (line #{index + 1})"
      end
      registrations.filter_map do |method, callbacks|
        "#{relative}: :#{method} under #{callbacks.join(', ')}" if callbacks.size > 1
      end
    end

    expect(offenders).to be_empty, "use one `after_commit :method, on: [...]` instead:\n#{offenders.join("\n")}"
  end
end
