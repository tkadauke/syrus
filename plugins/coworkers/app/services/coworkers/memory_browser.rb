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
      files = reader.files(
        revision,
        glob: CATEGORIES.map { |category| "memory/#{category}/**/*.md" },
        max_files: MAX_FILES,
        max_bytes: MAX_FILE_BYTES
      ).map { |path, blob| file_json(path, blob) }

      needle = search.to_s.strip.downcase
      files.select! { |file| "#{file[:path]}\n#{file[:content]}".downcase.include?(needle) } if needle.present?
      files.sort_by! { |file| sort_key(file) }

      { files: files, search: search.to_s.strip, truncated: files.any? { |file| file[:truncated] } }
    end

    private

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
