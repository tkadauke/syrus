# frozen_string_literal: true

require "rails_helper"

# Step error classes live on Steps::Base. A mixin module under Steps resolves
# a bare `StepFailed` lexically (Steps::<Module>::StepFailed, then Steps), not
# through the including step class, so the raise itself fails with NameError
# on the failure path -- the one path a spec rarely exercises. A failed
# prepare target once surfaced in production as
# "uninitialized constant Steps::PrepareTargetExecution::StepFailed".
RSpec.describe "step mixin modules qualify Steps::Base error constants" do
  ERROR_CONSTANTS = %w[StepFailed CannotProceed NoChangesProduced AgentTimedOut StepSkipped].freeze

  it "never raises a bare Steps::Base error constant inside a Steps module" do
    offenders = Dir[Rails.root.join("app/services/steps/**/*.rb")].flat_map do |path|
      source = File.read(path)
      next [] unless source.match?(/^  module \w+/)

      source.each_line.with_index(1).filter_map do |line, number|
        next unless line.match?(/\braise\s+(?:#{ERROR_CONSTANTS.join("|")})\b/)

        "#{Pathname.new(path).relative_path_from(Rails.root)}:#{number}: #{line.strip}"
      end
    end

    expect(offenders).to be_empty, "qualify as Steps::Base::<Error>:\n#{offenders.join("\n")}"
  end
end
