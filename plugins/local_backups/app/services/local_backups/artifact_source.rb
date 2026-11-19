module LocalBackups
  class ArtifactSource
    include Syrus::Plugin::BackupArtifactSource

    class Artifact
      attr_reader :backup_id, :checksum_algorithm, :checksum

      def initialize(backup_id:, root:, directory:, checksum_algorithm:, checksum:)
        @backup_id = backup_id
        @root = root
        @directory = directory
        @checksum_algorithm = checksum_algorithm
        @checksum = checksum
      end

      def entries
        @directory.glob("**/*").select(&:file?).reject(&:symlink?).map { |path| path.relative_path_from(@directory).to_s }.sort
      end

      def open(relative_path)
        relative = Pathname(relative_path)
        raise StorageRoot::Error, "artifact paths must be relative" if relative.absolute? || relative.each_filename.first == ".."

        resolved = @root.contain!(@directory.join(relative))
        prefix = "#{@directory}#{File::SEPARATOR}"
        raise StorageRoot::Error, "path escapes backup artifact" unless resolved.to_s.start_with?(prefix) && resolved.file?

        return File.open(resolved, "rb") unless block_given?

        File.open(resolved, "rb") { |io| yield io }
      end
    end

    def self.source_key = "local_backups"
    def self.list(**) = Backup.where(state: "completed").order(completed_at: :desc)
    def self.describe(backup_id, **) = Backup.find_by!(uuid: backup_id)
    def self.checksum(backup_id, **) = describe(backup_id).slice(:checksum_algorithm, :checksum)

    def self.open(backup_id, **)
      backup = describe(backup_id)
      root = StorageRoot.from_env
      directory = root.contain!(root.path.join(backup.artifact_path))
      artifact = Artifact.new(backup_id:, root:, directory:, checksum_algorithm: backup.checksum_algorithm, checksum: backup.checksum)
      return artifact unless block_given?

      yield artifact
    end

    def self.pin(backup_id, owner:, **) = describe(backup_id).update!(pinned: true)
    def self.release_pin(backup_id, owner:, **) = describe(backup_id).update!(pinned: false)

    def self.record_replication(backup_id, destination:, result:, **)
      backup = describe(backup_id)
      replication = backup.replications.find_or_initialize_by(destination_key: destination.to_s)
      replication.update!(result.slice(:state, :remote_reference, :remote_checksum, :uploaded_at, :verified_at, :error_summary))
      replication
    end
  end
end
