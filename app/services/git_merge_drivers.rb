require "shellwords"

# Registers repository-declared merge drivers in a managed clone. Git does not
# load driver commands from .gitattributes because doing so would allow a clone
# to execute arbitrary repository content without an explicit local opt-in.
class GitMergeDrivers
  Result = Data.define(:drivers) do
    def registered?(name) = drivers.key?(name.to_s)
  end

  class << self
    def register!(git:, path:)
      root = Pathname.new(path)
      attributes = root.join(".gitattributes")
      return Result.new({}) unless attributes.file?

      registered = driver_names(attributes).each_with_object({}) do |name, result|
        candidates = script_candidates(root, name)
        script = candidates.find { |candidate| candidate.file? && File.executable?(candidate) }
        unless script
          Rails.logger.warn(
            "[GitMergeDrivers] merge=#{name} has no executable driver; looked for #{candidates.join(', ')}"
          )
          next
        end

        command = "#{Shellwords.escape(script.expand_path.to_s)} %O %A %B"
        git.run("config", "merge.#{name}.name", "Repository merge driver #{name}", chdir: root.to_s)
        git.run("config", "merge.#{name}.driver", command, chdir: root.to_s)
        result[name] = command
      end

      Result.new(registered.freeze)
    end

    private

    def driver_names(attributes)
      attributes.each_line.flat_map { |line| line.scan(/(?:^|\s)merge=([^\s#]+)/).flatten }.uniq
    end

    def script_candidates(root, name)
      [ root.join("bin", "merge-#{name}"), root.join("bin", "merge-#{name.tr('_', '-')}") ].uniq
    end
  end
end
