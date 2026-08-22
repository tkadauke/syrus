require "rails_helper"

RSpec.describe "workflow launch funnel" do
  DIRECT_LAUNCH_PATTERNS = [
    /Workflows::[A-Za-z0-9_:]+\.instantiate/,
    /Workflow::TriggerKind\.template_for\([^)]*\)\.instantiate/,
    /\btemplate\.instantiate\(job:/,
    /\bworkflow_class\.instantiate\(/
  ].freeze

  ALLOWED_FILES = %w[
    app/services/work_units/launcher.rb
  ].freeze

  it "routes production workflow launches through WorkUnits::Launcher" do
    offenders = Rails.root.glob("app/**/*.rb").filter_map do |path|
      relative_path = path.relative_path_from(Rails.root).to_s
      next if ALLOWED_FILES.include?(relative_path)

      lines = File.readlines(path)
      matches = lines.filter_map.with_index(1) do |line, number|
        next unless DIRECT_LAUNCH_PATTERNS.any? { |pattern| line.match?(pattern) }

        "#{relative_path}:#{number}: #{line.strip}"
      end
      matches.presence
    end.flatten

    expect(offenders).to be_empty, <<~MESSAGE
      Production workflow creation must go through WorkUnits::Launcher so
      WorkIntent/WorkUnit shadow records cannot be missed. Move direct
      Workflows::* .instantiate calls behind the launcher or add an explicit
      exception here with a migration note.

      #{offenders.join("\n")}
    MESSAGE
  end
end
