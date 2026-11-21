module LocalBackups
  module PurgeGuard
    class ObjectHeld < StandardError; end

    def purge
      reject_held_object!
      super
    end

    def purge_later
      reject_held_object!
      super
    end

    private

    def reject_held_object!
      selecting = LocalBackups::Backup.where(state: "snapshotting").exists?
      return unless selecting || LocalBackups::ObjectHold.held?(id)

      raise ObjectHeld, "Active Storage object is held by an in-progress backup"
    end
  end
end
