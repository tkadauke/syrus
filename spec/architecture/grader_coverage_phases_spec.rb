require "rails_helper"

# `review` is the only phase whose workflows run a `coverage_analyze` step, so
# it is the only phase where a coverage artifact is read. A landing, promotion,
# or ci grader that collects coverage pays the whole cost -- instrumentation
# roughly doubles a suite's wall clock -- for something nothing looks at, and at
# landing that cost comes out of the per-grader timeout that decides whether a
# merge train lands at all. Dropping it once in a plugin is not enough: the next
# grader type would reintroduce it, so the rule is asserted over every
# registered `:grader_type` provider.
RSpec.describe "grader coverage phases" do
  # A config generous enough that every bundled grader type can synthesize
  # from it. Types that need more than this are reported rather than skipped.
  def coverage_config
    {
      "coverage" => true,
      "paths" => %w[spec],
      "spec_paths" => %w[spec],
      "test_paths" => %w[app/frontend],
      "project" => "App.xcodeproj",
      "scheme" => "App"
    }
  end

  def grade_steps_for(provider)
    Array(provider.grade_steps(config: coverage_config, default_failures: "strict"))
  rescue StandardError => e
    raise "#{provider}.grade_steps raised #{e.class}: #{e.message} -- extend #coverage_config so this type stays covered"
  end

  it "keeps coverage instrumentation out of every phase but review" do
    offenders = Syrus::PluginRegistry.providers_for(:grader_type).flat_map do |provider|
      grade_steps_for(provider).filter_map do |step|
        next if Array(step.metadata["coverage_outputs"]).empty?

        unreadable = step.phases.map(&:to_s) - Syrus::Plugin::GraderType::COVERAGE_PHASES
        next if unreadable.empty?

        "#{provider.type_name}/#{step.name} declares coverage_outputs for #{unreadable.join(', ')}"
      end
    end

    expect(offenders).to be_empty, -> { offenders.join("\n") }
  end

  it "still instruments the review entry, so the rule narrows coverage rather than removing it" do
    instrumented = Syrus::PluginRegistry.providers_for(:grader_type).flat_map do |provider|
      grade_steps_for(provider)
        .select { |step| Array(step.metadata["coverage_outputs"]).any? }
        .map { |step| "#{provider.type_name}/#{step.name}" }
    end

    # Guards the first example against passing vacuously: rspec and vitest are
    # the bundled types that can report coverage at all, and both must still
    # do so in review.
    expect(instrumented).to include("rspec/rspec-focused", "vitest/vitest-focused")
  end
end
