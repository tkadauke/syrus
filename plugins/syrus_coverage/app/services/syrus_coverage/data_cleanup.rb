module SyrusCoverage
  # Registered through Syrus::Installer *without* a `plugin:` scope on purpose:
  # disabling this plugin hides coverage, it does not delete the rows, and they
  # still have to go when the workflow or repository that owns them does.
  module DataCleanup
    def self.install_into(scope)
      scope.effect("workflow coverage hit maps") do
        Syrus::Host::DataCleanup.register("Workflow", "syrus_coverage.hit_maps") do |workflow|
          SyrusCoverage::HitMap.purge_for!(workflow)
        end
      end

      scope.effect("repository coverage snapshots") do
        Syrus::Host::DataCleanup.register("Repository", "syrus_coverage.snapshots") do |repository|
          SyrusCoverage::Snapshot.where(repository_id: repository.id).delete_all
        end
      end
    end
  end
end
