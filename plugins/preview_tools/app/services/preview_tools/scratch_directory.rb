require "fileutils"

module PreviewTools
  # Jails all file reads/writes to
  # <ChatWorkspace.path_for(chat_session)>/previews/<panel_id>/ so the
  # write/edit MCP tools can never escape into the rest of the persistent
  # chat workspace, the attached repository checkout, or another panel's
  # scratch files. Mirrors the cleanpath + prefix-check pattern
  # ChatWorkspace#safe_checkout_path already uses for repository paths.
  class ScratchDirectory
    class InvalidPath < StandardError; end

    MAX_FILE_BYTES = 2.megabytes

    def initialize(chat_session, panel_id)
      @root = ChatWorkspace.path_for(chat_session).join("previews", panel_id.to_s).cleanpath
    end

    attr_reader :root

    # Resolves relative_path within root, raising InvalidPath for anything
    # blank, empty after cleaning, or that escapes root (absolute paths,
    # "../" traversal).
    def resolve(relative_path)
      raise InvalidPath, "path is required" if relative_path.blank?

      candidate = root.join(relative_path).cleanpath
      unless candidate.to_s.start_with?("#{root}#{File::SEPARATOR}")
        raise InvalidPath, "#{relative_path.inspect} resolves outside the panel's scratch directory"
      end

      candidate
    end

    def write(relative_path, content)
      content = content.to_s
      if content.bytesize > MAX_FILE_BYTES
        raise InvalidPath, "#{relative_path.inspect} is #{content.bytesize} bytes, over the #{MAX_FILE_BYTES}-byte scratch file limit"
      end

      path = resolve(relative_path)
      FileUtils.mkdir_p(path.dirname)
      File.write(path, content)
      path
    end

    # Same old_string/new_string replacement contract as the harness's own
    # Edit tool: old_string must appear exactly once unless replace_all is
    # set. Returns the number of replacements made.
    def edit(relative_path, old_string, new_string, replace_all: false)
      path = resolve(relative_path)
      raise InvalidPath, "#{relative_path.inspect} does not exist in the scratch directory yet -- use write first" unless path.file?
      raise InvalidPath, "old_string must not be empty" if old_string.blank?

      content = File.read(path)
      occurrences = content.scan(old_string).length
      raise InvalidPath, "old_string was not found in #{relative_path.inspect}" if occurrences.zero?
      if occurrences > 1 && !replace_all
        raise InvalidPath, "old_string appears #{occurrences} times in #{relative_path.inspect} -- pass replace_all: true or include more surrounding context to make it unique"
      end

      updated = replace_all ? content.gsub(old_string, new_string) : content.sub(old_string, new_string)
      if updated.bytesize > MAX_FILE_BYTES
        raise InvalidPath, "#{relative_path.inspect} would be #{updated.bytesize} bytes, over the #{MAX_FILE_BYTES}-byte scratch file limit"
      end

      File.write(path, updated)
      replace_all ? occurrences : 1
    end

    def exist?(relative_path)
      resolve(relative_path).file?
    rescue InvalidPath
      false
    end

    # relative_path => absolute Pathname, for every file currently in the
    # scratch directory (empty hash if the directory hasn't been written to
    # yet).
    def files
      return {} unless root.directory?

      Pathname.glob(root.join("**", "*"), File::FNM_DOTMATCH)
        .select(&:file?)
        .each_with_object({}) do |file, acc|
          acc[file.relative_path_from(root).to_s] = file
        end
    end
  end
end
