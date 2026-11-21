# frozen_string_literal: true

require "rails_helper"

RSpec.describe "grading, preparation, and review provider failures" do
  let(:health) { Syrus::PluginRuntimeHealth.new }

  before do
    Syrus::PluginInvocation.runtime_health = health
  end

  after { Syrus::PluginInvocation.runtime_health = Syrus::PluginRuntimeHealth.new }

  def failing_provider(operation)
    Class.new do
      define_singleton_method(operation) { |**| raise "provider exploded" }
      define_singleton_method(:to_s) { "FailureFixtureProvider" }
    end
  end

  it "continues grade detection with built-in candidates and records plugin health" do
    provider = Class.new do
      def self.grade_candidates(_context) = raise("provider exploded")
    end
    register_ecosystem_provider(name: "failing-grade-candidates", provider:, implements: %i[grade_candidates])

    result = RepoGradeSignals.for(Dir.mktmpdir)

    expect(result.candidates).to eq([])
    expect(health.failures.last).to have_attributes(extension_point: "ecosystem", operation: "grade_candidates")
  end

  it "continues preparation with an empty auto-detected plan and records plugin health" do
    provider = Class.new do
      def self.detect_prepare(_context) = raise("provider exploded")
    end
    register_ecosystem_provider(name: "failing-prepare", provider:, implements: %i[detect_prepare])

    result = RepoPrepPlan.for(Dir.mktmpdir)

    expect(result.commands).to eq([])
    expect(health.failures.last).to have_attributes(extension_point: "ecosystem", operation: "detect_prepare")
  end

  it "falls through a failing CI parser and records plugin health" do
    provider = Class.new do
      def self.parse_ci_log(_context) = raise("provider exploded")
    end
    register_ecosystem_provider(name: "failing-ci-log", provider:, provisional: %i[parse_ci_log])

    result = CiLogParser.new("plain failure output", step_name: "test").parse

    expect(result[:parser]).to eq("fallback")
    expect(health.failures.last).to have_attributes(extension_point: "ecosystem", operation: "parse_ci_log")
  end

  it "omits a failing review presentation contribution and records plugin health" do
    provider = Class.new do
      ReviewPresentationContributions::COLLECTIONS.each do |operation|
        define_singleton_method(operation) { raise "provider exploded" }
      end
      def self.translation_namespaces = raise("provider exploded")
      def self.to_s = "FailureFixtureProvider"
    end
    allow(Syrus::PluginRegistry).to receive(:providers_for)
      .with(:review_presentation_contributor).and_return([ provider ])

    result = ReviewPresentationContributions.payload

    expect(result.values).to all(eq([]))
    expect(health.failures.last).to have_attributes(extension_point: "review_presentation_contributor")
  end
end
