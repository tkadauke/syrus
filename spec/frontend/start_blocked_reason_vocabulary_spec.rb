require "rails_helper"

# The backend has two blocked-reason vocabularies and the SPA has to render
# both: WorkUnit::BLOCKED_REASONS (canonical, read off the live WorkUnit) and
# WorkflowBlockProjection::REASON_MAP's keys (legacy StepDispatcher artifact
# strings, still what a terminal Workflow's artifacts carry).
#
# The SPA renders an unknown reason as its raw slug with an empty tooltip --
# `t(..., { defaultValue: reason })`. That is silent: nothing errors, the pill
# still draws, and the operator reads "main_branch_health" with no
# explanation. A job stalled for thirteen hours on main-branch health showed
# exactly that, because the frontend list only had the legacy
# "main_branch_broken" spelling.
RSpec.describe "start-blocked reason vocabulary" do
  LOCALES = %w[en de la].freeze
  PILL_PATH = "app/frontend/components/StartBlockedReasonPill.tsx".freeze

  def self.expected_reasons
    (WorkUnit::BLOCKED_REASONS + WorkUnits::WorkflowBlockProjection::REASON_MAP.keys)
      .reject { |reason| reason.include?(" ") } # free-text legacy artifact strings
      .uniq
      .sort
  end

  def locale_section(locale, key)
    path = Rails.root.join("app/frontend/i18n/locales/#{locale}/common.json")
    JSON.parse(File.read(path)).fetch(key, {})
  end

  it "covers every reason in the pill's tone map" do
    source = File.read(Rails.root.join(PILL_PATH))
    tones = source[/const TONES: Record<StartBlockedReason, [^>]+> = \{(.+?)\n\}/m, 1].to_s
    declared = tones.scan(/^\s*(\w+):/).flatten.sort

    expect(self.class.expected_reasons - declared).to be_empty,
      "StartBlockedReasonPill TONES is missing: #{(self.class.expected_reasons - declared).join(', ')}"
  end

  LOCALES.each do |locale|
    it "has a #{locale} label and tooltip for every reason" do
      labels = locale_section(locale, "start_blocked_reasons").keys
      tooltips = locale_section(locale, "start_blocked_reason_tooltips").keys

      expect(self.class.expected_reasons - labels).to be_empty,
        "#{locale}/common.json start_blocked_reasons is missing: #{(self.class.expected_reasons - labels).join(', ')}"
      expect(self.class.expected_reasons - tooltips).to be_empty,
        "#{locale}/common.json start_blocked_reason_tooltips is missing: #{(self.class.expected_reasons - tooltips).join(', ')}"
    end
  end
end
