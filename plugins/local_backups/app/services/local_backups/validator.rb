require "digest"

module LocalBackups
  class Validator
    class Invalid < StandardError; end

    def initialize(root: StorageRoot.new)
      @root = root
    end

    def call(backup)
      artifact = @root.contained(backup.artifact_relative_path)
      checksums = artifact.join("checksums.sha256")
      raise Invalid, "checksum inventory is missing" unless checksums.file?

      checksums.each_line do |line|
        expected, relative = line.strip.split(/\s+/, 2)
        raise Invalid, "checksum inventory is malformed" unless expected&.match?(/\A[0-9a-f]{64}\z/) && relative.present?

        path = contained_file(artifact, relative)
        raise Invalid, "checksum mismatch for #{relative}" unless Digest::SHA256.file(path).hexdigest == expected
      end
      Manifest.read(artifact.join("manifest.json"))
      backup.update!(validated_at: Time.current, verification_state: "valid")
      backup
    rescue StandardError => e
      backup.update_columns(verification_state: "invalid", error_class: e.class.name, error_summary: e.message.to_s.first(1000))
      raise
    end

    private

    def contained_file(artifact, relative)
      clean = Pathname.new(relative).cleanpath
      raise Invalid, "checksum path escapes artifact" if clean.absolute? || clean.each_filename.first == ".."

      path = artifact.join(clean).realpath
      raise Invalid, "checksum path escapes artifact" unless path.to_s.start_with?("#{artifact.realpath}#{File::SEPARATOR}")
      raise Invalid, "checksum target is not a file" unless path.file?
      path
    rescue Errno::ENOENT
      raise Invalid, "checksum target is missing"
    end
  end
end
