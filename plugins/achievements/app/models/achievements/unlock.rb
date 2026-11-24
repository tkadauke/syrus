module Achievements
  # The canonical record that a definition was unlocked. One row per
  # (definition, owner): an instance unlock is owned by the installation, a user
  # unlock by the attributed user. The unique index makes repeated delivery of
  # the same domain event idempotent; `record!` is the only intended writer.
  class Unlock < ApplicationRecord
    self.table_name = "achievements_unlocks"

    EVIDENCE_MAX_BYTES = 4096
    EVIDENCE_MAX_DEPTH = 3
    EVIDENCE_MAX_STRING = 500
    INSTANCE_OWNER = "instance".freeze

    # Registry the definition is validated against; `record!` sets it so a
    # custom registry is honoured consistently. Defaults to the bundled catalog.
    attr_writer :registry

    has_many :acknowledgments, class_name: "Achievements::Acknowledgment",
      foreign_key: :unlock_id, inverse_of: :unlock, dependent: :delete_all

    validates :definition_key, :definition_version, :scope, :owner_key, :unlocked_at, presence: true
    validates :owner_key, uniqueness: { scope: :definition_key }
    validate :definition_matches_registry
    validate :owner_matches_scope
    validate :subject_is_complete
    validate :evidence_is_bounded_primitive_json

    scope :for_user, ->(user_id) { where(user_id: user_id) }
    scope :instance_wide, -> { where(scope: "instance") }

    def self.owner_key_for(definition, user_id)
      definition.instance_scoped? ? INSTANCE_OWNER : "user:#{user_id}"
    end

    # Idempotent: returns [unlock, created]. A second call for the same
    # definition and owner returns the original row untouched, keeping the
    # first-unlock evidence. Races are resolved by the unique index.
    def self.record!(definition_key, user_id: nil, subject: nil, evidence: nil, registry: Achievements::Registry.default, at: Time.current)
      definition = registry.fetch(definition_key)
      owner_key = owner_key_for(definition, user_id)
      existing = find_by(definition_key: definition.key, owner_key: owner_key)
      return [ existing, false ] if existing

      unlock = new(
        definition_key: definition.key, definition_version: definition.version,
        scope: definition.scope.to_s, owner_key: owner_key,
        user_id: definition.user_scoped? ? user_id : nil,
        subject_type: subject && subject_kind(subject), subject_id: subject&.id,
        evidence: evidence, unlocked_at: at
      )
      unlock.registry = registry
      unlock.save!
      [ unlock, true ]
    rescue ActiveRecord::RecordNotUnique
      [ find_by!(definition_key: definition.key, owner_key: owner_key), false ]
    end

    def self.subject_kind(subject) = subject.class.name.underscore

    def acknowledged_by?(user_id) = acknowledgments.exists?(user_id: user_id)

    # Idempotent per user. Only the attributed user may acknowledge a user
    # unlock; any user may acknowledge an instance unlock, separately.
    def acknowledge!(user_id, at: Time.current)
      raise ArgumentError, "user #{user_id} cannot acknowledge unlock #{id}" if scope == "user" && self.user_id != user_id

      acknowledgments.find_by(user_id: user_id) || acknowledgments.create!(user_id: user_id, acknowledged_at: at)
    rescue ActiveRecord::RecordNotUnique
      acknowledgments.find_by!(user_id: user_id)
    end

    private

    def definition_matches_registry
      definition = (@registry || Achievements::Registry.default).find(definition_key)
      return errors.add(:definition_key, I18n.t("achievements.errors.not_registered")) if definition.nil?

      errors.add(:scope, I18n.t("achievements.errors.scope_mismatch")) unless scope == definition.scope.to_s
      if subject_type.present? && !definition.subject_kinds.include?(subject_type.to_sym)
        errors.add(:subject_type, I18n.t("achievements.errors.subject_type_not_allowed"))
      end
    end

    def owner_matches_scope
      case scope
      when "instance"
        errors.add(:user_id, I18n.t("achievements.errors.must_be_blank_for_instance")) if user_id.present?
        errors.add(:owner_key, I18n.t("achievements.errors.must_be_instance_owner", owner: INSTANCE_OWNER)) unless owner_key == INSTANCE_OWNER
      when "user"
        return errors.add(:user_id, I18n.t("achievements.errors.user_required")) if user_id.blank?

        errors.add(:owner_key, I18n.t("achievements.errors.must_be_user_owner", user_id: user_id)) unless owner_key == "user:#{user_id}"
      end
    end

    def subject_is_complete
      errors.add(:subject_id, I18n.t("achievements.errors.subject_id_requires_type")) if subject_type.present? && subject_id.blank?
      errors.add(:subject_type, I18n.t("achievements.errors.subject_type_requires_id")) if subject_id.present? && subject_type.blank?
    end

    def evidence_is_bounded_primitive_json
      # Check the raw assignment: the JSON column would silently stringify keys.
      return unless new_record? || will_save_change_to_evidence?

      raw = evidence_before_type_cast
      return if raw.nil?

      problem = Evidence.problem_with(raw, max_depth: EVIDENCE_MAX_DEPTH, max_string: EVIDENCE_MAX_STRING)
      problem ||= I18n.t("achievements.errors.evidence_too_large", bytes: EVIDENCE_MAX_BYTES) if raw.to_json.bytesize > EVIDENCE_MAX_BYTES
      errors.add(:evidence, problem) if problem
    end

    # Primitive-JSON walker: only nil, booleans, numbers, strings, arrays, and
    # string-keyed hashes, nested to a bounded depth.
    module Evidence
      def self.problem_with(value, max_depth:, max_string:, depth: 1)
        return "is nested deeper than #{max_depth} levels" if depth > max_depth

        case value
        when nil, true, false, Integer then nil
        when Float then value.finite? ? nil : "contains a non-finite number"
        when String then value.length > max_string ? "contains a string longer than #{max_string} characters" : nil
        when Array then first_problem(value, max_depth, max_string, depth)
        when Hash
          return "has non-string keys" unless value.keys.all? { |key| key.is_a?(String) }

          first_problem(value.values, max_depth, max_string, depth)
        else "contains a non-primitive #{value.class}"
        end
      end

      def self.first_problem(values, max_depth, max_string, depth)
        values.each do |entry|
          problem = problem_with(entry, max_depth:, max_string:, depth: depth + 1)
          return problem if problem
        end
        nil
      end
    end
  end
end
