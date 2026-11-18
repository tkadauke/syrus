# frozen_string_literal: true

require "rails_helper"

RSpec.describe "grading, preparation, and review provider failures" do
  let(:health) { Syrus::PluginRuntimeHealth.new }

  before do
    Syrus::PluginInvocation.runtime_health = health
    allow(Syrus::PluginRegistry).to receive(:providers_for).and_call_original
  end

  after { Syrus::PluginInvocation.runtime_health = Syrus::PluginRuntimeHealth.new }

  def failing_provider(operation)
    Class.new do
      define_singleton_method(operation) { |**| raise "provider exploded" }
      define_singleton_method(:to_s) { "FailureFixtureProvider" }
    end
  end

  it "continues grade detection with built-in candidates and records plugin health" do
    provider = failing_provider(:grade_candidates)
    allow(Syrus::PluginRegistry).to receive(:providers_for).with(:grade_detector).and_return([ provider ])

    result = RepoGradeSignals.for(Dir.mktmpdir)

    expect(result.candidates).to eq([])
    expect(health.failures.last).to have_attributes(extension_point: "grade_detector", operation: "grade_candidates")
  end

  it "continues preparation with an empty auto-detected plan and records plugin health" do
    provider = Class.new do
      def self.detect?(_path) = raise("provider exploded")
      def self.to_s = "FailureFixtureProvider"
    end
    allow(Syrus::PluginRegistry).to receive(:providers_for).with(:prepare_detector).and_return([ provider ])

    result = RepoPrepPlan.for(Dir.mktmpdir)

    expect(result.commands).to eq([])
    expect(health.failures.last).to have_attributes(extension_point: "prepare_detector", operation: "detect?")
  end

  it "falls through a failing CI parser and records plugin health" do
    provider = failing_provider(:call)
    allow(Syrus::PluginRegistry).to receive(:providers_for).with(:ci_log_parser).and_return([ provider ])

    result = CiLogParser.new("plain failure output", step_name: "test").parse

    expect(result[:parser]).to eq("fallback")
    expect(health.failures.last).to have_attributes(extension_point: "ci_log_parser", operation: "call")
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
