module Achievements
  # What a user may see and do with unlocks. Visibility: every instance unlock
  # plus the user's own user unlocks; another user's unlock is indistinguishable
  # from one that does not exist. No operation here creates, deletes, or edits
  # an Unlock -- only per-user acknowledgments move.
  class Reveals
    class NotFound < StandardError; end

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

    def known(relation) = relation.select { |unlock| @registry.find(unlock.definition_key) }

    def find!(unlock_id)
      unlock = visible_unlocks.find_by(id: unlock_id)
      raise NotFound unless unlock && definition_for(unlock)

      unlock
    end
  end
end
