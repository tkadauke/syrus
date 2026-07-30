module SyrusRails
  class MigrationDiffRenderer
    extend Syrus::Plugin::ArtifactRenderer

    def self.artifact_type = "rails_migration_diff"
    def self.renderer_type = :migration_diff
  end
end
