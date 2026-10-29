module Coworkers
  class MemoryBrowser
    MAX_FILES = 1_000
    MAX_FILE_BYTES = 256.kilobytes
    CATEGORIES = %w[daily people repos banks].freeze

    def initialize(coworker:, repository:, user:)
      @coworker = coworker
      @repository = repository
      @user = user
    end

    def call(search: nil)
      reader = RepositoryContent.for(@repository, user: @user)
      revision = reader.resolve("coworkers/#{@coworker.handle}")
      entries, partial_tree = memory_entries(reader, revision)
      entries.sort_by! { |entry| sort_key({ category: entry.path.split("/")[1], name: File.basename(entry.path, ".md") }) }
      over_limit = entries.size > MAX_FILES
      files = entries.first(MAX_FILES).map do |entry|
        file_json(entry.path, reader.read(revision, entry.path, max_bytes: MAX_FILE_BYTES))
      end
      truncated_files = files.any? { |file| file[:truncated] }

      needle = search.to_s.strip.downcase
      files.select! { |file| "#{file[:path]}\n#{file[:content]}".downcase.include?(needle) } if needle.present?
      files.sort_by! { |file| sort_key(file) }

      {
        files: files,
        search: search.to_s.strip,
        truncated: truncated_files,
        partial: partial_tree || over_limit,
        search_incomplete: needle.present? && (partial_tree || over_limit || truncated_files)
      }
    end

    private

    def memory_entries(reader, revision)
      entries = reader.tree(revision)
      [ select_memory_files(entries), false ]
    rescue RepositoryContent::Truncated => error
      [ select_memory_files(error.partial), true ]
    end

    def select_memory_files(entries)
      patterns = CATEGORIES.map { |category| "memory/#{category}/**/*.md" }
      entries.select { |entry| entry.file? && RepositoryContent::Glob.match?(patterns, entry.path) }
    end

    def file_json(path, blob)
      category = path.split("/")[1]
      {
        path: path,
        category: category,
        name: File.basename(path, ".md"),
        content: blob.text,
        truncated: blob.truncated
      }
    end

    def sort_key(file)
      file[:category] == "daily" ? [ 0, -file[:name].delete("-").to_i ] : [ CATEGORIES.index(file[:category]) || CATEGORIES.length, file[:name].downcase ]
    end
  end
end
