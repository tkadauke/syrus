require "rails_helper"

RSpec.describe "workflow launch funnel" do
  DIRECT_CREATE_PATTERNS = [
    /Workflows::[A-Za-z0-9_:]+\.instantiate/,
    /Workflow::TriggerKind\.template_for\([^)]*\)\.instantiate/,
    /\btemplate\.instantiate\(job:/,
    /\bworkflow_class\.instantiate\(/
  ].freeze

  DIRECT_START_PATTERNS = [
    /\bStepDispatcher\.start_workflow\(/,
    /\bStepDispatcher\.resume_deferred_phase\(/
  ].freeze

  ALLOWED_FILES = %w[
    app/services/work_units/deferred_phase_resume.rb
    app/services/work_units/launcher.rb
  ].freeze

  it "routes production workflow launches through WorkUnits::Launcher" do
    offenders = Rails.root.glob("app/**/*.rb").filter_map do |path|
      relative_path = path.relative_path_from(Rails.root).to_s
      next if ALLOWED_FILES.include?(relative_path)

      lines = File.readlines(path)
      matches = lines.filter_map.with_index(1) do |line, number|
        pattern =
          if DIRECT_CREATE_PATTERNS.any? { |candidate| line.match?(candidate) }
            "direct workflow creation"
          elsif DIRECT_START_PATTERNS.any? { |candidate| line.match?(candidate) }
            "direct workflow start"
          end
        next unless pattern

        "#{relative_path}:#{number}: #{pattern}: #{line.strip}"
      end
      matches.presence
    end.flatten

    expect(offenders).to be_empty, <<~MESSAGE
      Production workflow creation and starts must go through
      WorkUnits::Launcher so WorkIntent/WorkUnit shadow records cannot be
      missed. Move direct Workflows::* .instantiate or
      StepDispatcher.start_workflow/resume_deferred_phase calls behind the
      WorkUnit facades, or add an explicit exception here with a migration
      note.

      #{offenders.join("\n")}
    MESSAGE
  end
end
