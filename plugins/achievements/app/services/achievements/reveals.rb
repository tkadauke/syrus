module Achievements
  # What a user may see and do with unlocks. Visibility: every instance unlock
  # plus the user's own user unlocks; another user's unlock is indistinguishable
  # from one that does not exist. No operation here creates, deletes, or edits
  # an Unlock -- only per-user acknowledgments move.
  class Reveals
    class NotFound < StandardError; end

    EVIDENCE_SUBJECTS = {
      "job" => ->(user) { ::Job.visible_to(user) },
      "epic" => ->(user) { ::Epic.accessible_to(user) }
    }.freeze

    CONFIRM_RESET_ALL = "reset_all_acknowledgments".freeze

    def initialize(user, registry: Achievements::Registry.default)
      @user = user
      @registry = registry
    end

    def visible_unlocks
      Unlock.where(scope: "instance").or(Unlock.where(scope: "user", user_id: @user.id)).order(:unlocked_at, :id)
    end

    # Unlocks the user has not yet acknowledged, oldest first, limited to
    # definitions that still exist.
    def pending
      acknowledged = Acknowledgment.where(user_id: @user.id).select(:unlock_id)
      known(visible_unlocks.where.not(id: acknowledged))
    end

    def listing
      unlocks = known(visible_unlocks)
      acknowledged_at = Acknowledgment.where(user_id: @user.id, unlock_id: unlocks.map(&:id)).pluck(:unlock_id, :acknowledged_at).to_h
      unlocks.map { |unlock| [ unlock, acknowledged_at[unlock.id] ] }
    end

    # Registry definitions this user has not unlocked (an instance definition
    # unlocked by anyone counts as unlocked). Hidden ones are reduced to their
    # scope: key, category, rarity, and copy would spoil them.
    def locked
      unlocked = visible_unlocks.pluck(:definition_key).to_set
      @registry.definitions.reject { |definition| unlocked.include?(definition.key) }
    end

    # Pending reveals about one Job or Epic the user is looking at. Anything the
    # user cannot access yields nothing, so the filter cannot confirm that an
    # inaccessible record is the subject of a milestone.
    def pending_for_subject(type, id)
      type = type.to_s
      return [] unless EVIDENCE_SUBJECTS.key?(type) && subject_accessible?(type, id.to_i)

      pending.select { |unlock| unlock.subject_type == type && unlock.subject_id == id.to_i }
    end

    # unlock id => { kind:, id:, slug: } for unlocks whose subject the user may
    # open. A subject that is gone or not accessible produces no entry.
    def evidence_links(unlocks)
      unlocks.group_by(&:subject_type).flat_map do |type, group|
        next [] unless EVIDENCE_SUBJECTS.key?(type)

        ids = group.filter_map(&:subject_id).uniq
        records = EVIDENCE_SUBJECTS.fetch(type).call(@user).where(id: ids).index_by(&:id)
        group.filter_map do |unlock|
          record = records[unlock.subject_id]
          [ unlock.id, { kind: type, id: record.id, slug: record.slug } ] if record
        end
      end.to_h
    end

    def acknowledge!(unlock_id)
      unlock = find!(unlock_id)
      unlock.acknowledge!(@user.id)
      unlock
    end

    # Make one reveal pending again for this user only.
    def replay!(unlock_id)
      unlock = find!(unlock_id)
      Acknowledgment.where(unlock_id: unlock.id, user_id: @user.id).delete_all
      unlock
    end

    def reset_own!
      Acknowledgment.where(user_id: @user.id).delete_all
    end

    # Everyone's acknowledgments. The caller proves intent with the confirmation
    # token and must already have authorized the user as an admin.
    def self.reset_all!(confirmation:)
      raise ArgumentError, "confirmation required" unless confirmation == CONFIRM_RESET_ALL

      Acknowledgment.delete_all
    end

    def definition_for(unlock) = @registry.find(unlock.definition_key)

    private

    def subject_accessible?(type, id)
      EVIDENCE_SUBJECTS.fetch(type).call(@user).where(id: id).exists?
    end

    def known(relation) = relation.select { |unlock| @registry.find(unlock.definition_key) }

    def find!(unlock_id)
      unlock = visible_unlocks.find_by(id: unlock_id)
      raise NotFound unless unlock && definition_for(unlock)

      unlock
    end
  end
end
