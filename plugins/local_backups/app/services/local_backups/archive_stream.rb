require "rubygems/package"
require "tempfile"

module LocalBackups
  class ArchiveStream
    CHUNK_SIZE = 64.kilobytes

    def initialize(root: StorageRoot.new)
      @root = root
    end

    def open(backup)
      artifact = @root.contained(backup.artifact_relative_path)
      tempfile = Tempfile.new(["syrus-backup-#{backup.uuid}-", ".tar"])
      tempfile.binmode
      Gem::Package::TarWriter.new(tempfile) do |tar|
        artifact.find do |path|
          next if path == artifact
          raise StorageRoot::Invalid, "backup archive contains a symlink" if path.symlink?

          relative = path.relative_path_from(artifact).to_s
          stat = path.stat
          if path.directory?
            tar.mkdir(relative, stat.mode)
          elsif path.file?
            tar.add_file_simple(relative, stat.mode, stat.size) do |output|
              path.open("rb") do |input|
                loop do
                  chunk = input.read(CHUNK_SIZE)
                  break unless chunk
                  output.write(chunk)
                end
              end
            end
          end
        end
      end
      tempfile.flush
      tempfile.rewind
      tempfile
    rescue StandardError
      tempfile&.close!
      raise
    end

    def body(tempfile, offset:, length:)
      Enumerator.new do |output|
        tempfile.seek(offset)
        remaining = length
        while remaining.positive? && (chunk = tempfile.read([CHUNK_SIZE, remaining].min))
          output << chunk
          remaining -= chunk.bytesize
        end
      ensure
        tempfile.close!
      end
    end
  end
end
