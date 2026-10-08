require "rails_helper"

# Execution capabilities are declared by whoever creates the work -- the
# proposing agent through `planned_execution`, an operator through the API, or
# the repository through `.syrus.yml`. They are never guessed from a Job's
# title or body.
#
# This existed as keyword matching and could not be made to work. A bug report
# filed from a phone matched "iphone" inside a User-Agent. A Kotlin/JVM Job
# matched the sentence saying iOS was "intentionally out of scope". Nothing in
# the fleet advertises macOS, so each one blocked on `no_capable_worker` and
# retried every couple of minutes indefinitely, and each round of teaching the
# matcher an exception produced a new escape.
#
# It is guarded here rather than with a behavioural spec on purpose. The
# planner swallows errors and falls back to the default, and
# RepoDefaultBranchSyrusYml does not resolve for the unsaved probe Jobs these
# paths build, so a spec asserting "this text yields Linux" passes whether or
# not the matching is present -- it cannot fail, which makes it worse than no
# spec at all. Reintroducing the matcher is a source-level fact, so check that.
RSpec.describe "planned execution placement" do
  PLACEMENT_FILES = %w[
    app/services/planned_execution_planner.rb
    app/models/planned_execution_requirement.rb
    app/services/planned_execution_params.rb
  ].freeze

  # The words the old matcher keyed on. Any of them next to a capability
  # decision means prose is steering placement again.
  PLATFORM_WORDS = %w[
    iphone ipad xcode xcodebuild swiftui uikit xcworkspace xcodeproj
    msbuild powershell winui ubuntu debian glibc systemd
  ].freeze

  it "has no analyzer that reads a Job's text" do
    expect(File.exist?(Rails.root.join("app/services/planned_execution_request_analyzer.rb"))).to be(false),
      "PlannedExecutionRequestAnalyzer inferred placement from the Job's title and body. " \
      "Capabilities are declared, not guessed -- see this spec's header."

    expect(defined?(PlannedExecutionRequestAnalyzer)).to be_nil
  end

  it "decides placement without reading the Job's title or body" do
    offenders = PLACEMENT_FILES.filter_map do |relative|
      path = Rails.root.join(relative)
      next unless File.exist?(path)

      File.readlines(path).each_with_index.filter_map do |line, index|
        next if line.strip.start_with?("#")
        next unless line.match?(/\bissue_title\b|\bissue_body\b/)

        "#{relative}:#{index + 1}: #{line.strip}"
      end.presence
    end.flatten

    expect(offenders).to be_empty, <<~MSG
      Placement must come from a declaration, not from the Job's text:

      #{offenders.join("\n")}
    MSG
  end

  it "matches no platform keyword anywhere in the placement path" do
    pattern = /\b(#{PLATFORM_WORDS.join('|')})\b/i
    offenders = PLACEMENT_FILES.filter_map do |relative|
      path = Rails.root.join(relative)
      next unless File.exist?(path)

      File.readlines(path).each_with_index.filter_map do |line, index|
        next if line.strip.start_with?("#")
        next unless line.match?(pattern)

        "#{relative}:#{index + 1}: #{line.strip}"
      end.presence
    end.flatten

    expect(offenders).to be_empty, <<~MSG
      A platform keyword list is how the previous inference worked. Placement
      is declared by the proposal, the operator, or .syrus.yml:

      #{offenders.join("\n")}
    MSG
  end
end
