# frozen_string_literal: true

require "rails_helper"

RSpec.describe "grading, preparation, and review plugin invocation boundaries" do
  # These methods only expose registered provider classes. They do not invoke
  # provider behavior, so there is no runtime call for the boundary to wrap.
  LOOKUP_ONLY_METHOD_ALLOWLIST = {
    "app/services/adjudicators.rb" => %w[all],
    "app/services/app/diff_review_annotations_payload.rb" => %w[providers],
    "plugins/main_branch_health/app/services/main_branch_failure_classifier.rb" => %w[test_evidence_providers],
    "app/services/review_presentation_contributions.rb" => %w[providers],
    "app/services/reviewer_targets.rb" => %w[providers],
    "app/services/test_evidence_lookup.rb" => %w[test_evidence_providers]
  }.freeze

  ROOT_FILES = %w[
    app/services/agent_environment_snapshot.rb
    app/services/adjudicators.rb
    app/services/app/diff_review_annotations_payload.rb
    app/services/app/diff_review_file_classifier.rb
    app/services/app/job_detail_payload.rb
    app/services/base_revision_retry.rb
    app/services/ci_log_parser.rb
    app/services/grader_command_spans/plan.rb
    app/services/grader_input_materialization.rb
    app/services/isolated_repro_recorder.rb
    plugins/main_branch_health/app/services/main_branch_failure_classifier.rb
    app/services/merge_train_multisect.rb
    app/services/post_implementation_review_required_mcp_tools.rb
    app/services/repo_grade_signals.rb
    app/services/repo_prep_plan.rb
    app/services/repository_execution_probe_runner.rb
    app/services/review_context_contributions.rb
    app/services/review_presentation_contributions.rb
    app/services/reviewer_targets.rb
    app/services/syrus_yml.rb
    app/services/test_evidence_lookup.rb
    app/services/unlanding/create.rb
  ].freeze

  def method_section(lines, provider_line)
    start = provider_line.downto(0).find { |index| lines[index].match?(/^\s*def\s/) } || 0
    indentation = lines[start][/^\s*/].to_s.length
    finish = ((start + 1)...lines.length).find do |index|
      lines[index].match?(/^\s*def\s/) && lines[index][/^\s*/].to_s.length == indentation
    end || lines.length
    [ lines[start][/def\s+(?:self\.)?([^\s(=]+)/, 1], lines[start...finish].join ]
  end

  it "guards provider invocations in grading, preparation, and review services" do
    paths = ROOT_FILES + Dir["app/services/steps/**/*.rb", "app/services/workflows/**/*.rb"]
    offenders = paths.uniq.sort.filter_map do |path|
      lines = File.readlines(Rails.root.join(path))
      unguarded = lines.each_index.select do |index|
        next false unless lines[index].include?("PluginRegistry.providers_for")

        method_name, section = method_section(lines, index)
        lookup_only = LOOKUP_ONLY_METHOD_ALLOWLIST.fetch(path, []).include?(method_name)
        !lookup_only && !section.include?("Syrus::PluginInvocation.call") && !section.include?("invoke(")
      end
      "#{path}:#{unguarded.map { |index| index + 1 }.join(',')}" if unguarded.any?
    end

    expect(offenders).to be_empty, <<~MESSAGE
      Provider calls in grading, preparation, and review code must use
      Syrus::PluginInvocation.call. Add a deliberately documented lookup-only
      method exception only when no provider behavior runs.
      Offenders: #{offenders.join('; ')}
    MESSAGE
  end
end
