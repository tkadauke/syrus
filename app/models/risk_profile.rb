# A project's posture, as one reviewable value (workflow-engine-v3 C0).
#
# "How much do we tolerate a broken main?" is one question. Today it is
# answered by six knobs across two scopes, consumed in 21 files, and they do
# not compose: an instance hosting a throwaway repo and a production service
# has to pick one posture for both, because two of the six are instance-wide.
# A seventh knob makes that worse.
#
# A profile answers all of them consistently, and is a single object a person
# can review. Individual overrides still win -- the profile is the default
# posture, not a cage -- but a repository that has not overridden anything has
# a risk posture readable from one value, which is this phase's success
# criterion.
class RiskProfile
  Entry = Data.define(
    :key, :label, :description,
    # The main-branch six, answered consistently.
    :main_branch_health_enabled, :main_branch_repair_enabled,
    :main_branch_repair_auto_approve, :main_branch_repair_blocks_work,
    :main_branch_breakage_policy,
    # The attention posture, which is the same question asked of failures.
    :escalates_landing_failures, :allows_agentic_dismissal
  )

  BUILT_IN = [
    Entry.new(
      key: "prototype",
      label: "Prototype",
      description: "Throwaway or experimental work. Main is not graded, nothing blocks, " \
                   "and failures are not worth waking anyone for.",
      main_branch_health_enabled: false,
      main_branch_repair_enabled: false,
      main_branch_repair_auto_approve: false,
      main_branch_repair_blocks_work: false,
      main_branch_breakage_policy: "isolate_unrelated_failures",
      escalates_landing_failures: false,
      allows_agentic_dismissal: true
    ),
    Entry.new(
      key: "standard",
      label: "Standard",
      description: "The default. Main is graded and repaired, unrelated failures are " \
                   "isolated rather than halting everything, and a landing failure is " \
                   "worth a person's attention once the cheaper rungs have declined.",
      main_branch_health_enabled: true,
      main_branch_repair_enabled: true,
      main_branch_repair_auto_approve: false,
      main_branch_repair_blocks_work: false,
      main_branch_breakage_policy: "isolate_unrelated_failures",
      escalates_landing_failures: true,
      allows_agentic_dismissal: true
    ),
    Entry.new(
      key: "production",
      label: "Production",
      description: "Broken main halts unrelated work, repairs are never auto-approved, " \
                   "and no agent may dismiss a failing check -- every override is human " \
                   "and audited.",
      main_branch_health_enabled: true,
      main_branch_repair_enabled: true,
      main_branch_repair_auto_approve: false,
      main_branch_repair_blocks_work: true,
      main_branch_breakage_policy: "strict",
      escalates_landing_failures: true,
      allows_agentic_dismissal: false
    )
  ].freeze

  BY_KEY = BUILT_IN.index_by(&:key).freeze

  # The posture Syrus actually ships: grade main, repair it, never
  # auto-approve the repair, halt unrelated work, strict breakage policy. That
  # is `production`, not `standard` -- worth naming rather than papering over,
  # because it means a fresh repository is strict by default and relaxing it is
  # a deliberate choice.
  SHIPPED_DEFAULT = "production".freeze

  # What the plan proposes as the everyday posture. Adopting it for existing
  # projects is a migration someone decides to run, not a default that changes
  # underneath them.
  DEFAULT = "standard".freeze

  # The settings a profile answers. Anything not listed here is not the
  # profile's business, which is what keeps it a posture rather than a second
  # settings table.
  GOVERNED = %i[
    main_branch_health_enabled main_branch_repair_enabled
    main_branch_repair_auto_approve main_branch_repair_blocks_work
    main_branch_breakage_policy escalates_landing_failures allows_agentic_dismissal
  ].freeze

  def self.keys = BY_KEY.keys.freeze
  def self.exists?(key) = BY_KEY.key?(key.to_s)

  def self.fetch(key)
    BY_KEY.fetch(key.to_s) { raise ArgumentError, "unknown risk profile=#{key.inspect}" }
  end

  def self.default = fetch(DEFAULT)

  # Resolves one governed setting for a profile, honouring an explicit
  # override. `overrides` is whatever the repository actually set; nil means
  # "not overridden", which is why the columns have to be nullable for an
  # override to be distinguishable from a false.
  def self.resolve(setting, profile:, overrides: {})
    raise ArgumentError, "#{setting.inspect} is not governed by a risk profile" unless GOVERNED.include?(setting.to_sym)

    override = overrides.to_h.symbolize_keys[setting.to_sym]
    return override unless override.nil?

    fetch(profile || DEFAULT).public_send(setting)
  end
end
