module Achievements
  # One achievement definition: stable key plus versioned metadata. Immutable
  # and primitive-only so it can be serialized into fixtures and docs.
  #
  # `version` is bumped when the meaning of an unlock changes; unlocks record
  # the version they were awarded under. `trigger` and `evaluator` are opaque
  # identities (a domain-event name and an evaluator class name) resolved by the
  # later evaluation work, never by this registry.
  Definition = Data.define(
    :key, :version, :scope, :trigger, :evaluator, :subject_kinds,
    :visibility, :category, :rarity, :presentation
  ) do
    def self.build(key:, scope:, trigger:, evaluator:, subject_kinds:, category:, rarity:,
                   version: 1, visibility: :visible, presentation: {})
      new(
        key: key.to_s, version: version, scope: scope.to_sym, trigger: trigger.to_s,
        evaluator: evaluator.to_s, subject_kinds: Array(subject_kinds).map(&:to_sym).freeze,
        visibility: visibility.to_sym, category: category.to_sym, rarity: rarity.to_sym,
        presentation: presentation.to_h.deep_stringify_keys.freeze
      )
    end

    def hidden? = visibility == :hidden
    def instance_scoped? = scope == :instance
    def user_scoped? = scope == :user
  end
end
