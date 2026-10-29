require "digest"
require "json"

module ContainerExecution
  class DevcontainerSpec
    PATHS = [ ".devcontainer/devcontainer.json", ".devcontainer.json" ].freeze

    Result = Data.define(:config, :source, :revision) do
      def image = config["image"].to_s.presence
      def build = config["build"]
      def fingerprint = Digest::SHA256.hexdigest(JSON.generate(config) + revision.to_s)
    end

    def self.for_job(job)
      new(repository: job.repository, user: job.user).resolve
    end

    def initialize(repository:, user:)
      @repository = repository
      @user = user
    end

    def resolve
      content = RepositoryContent.for(repository, user: user)
      revision = content.resolve(repository.default_branch)
      PATHS.each do |path|
        blob = content.read_if_present(revision, path)
        next unless blob

        config = JSON.parse(strip_trailing_commas(strip_json_comments(blob.text)))
        return Result.new(config: config, source: path, revision: revision.id) if usable?(config)
      end
      nil
    rescue RepositoryContent::Error, JSON::ParserError => e
      Rails.logger.warn("[ContainerExecution::DevcontainerSpec] unavailable for #{repository.slug}: #{e.class}: #{e.message}")
      nil
    end

    private

    attr_reader :repository, :user

    def usable?(config)
      config.is_a?(Hash) && (config["image"].present? || config["build"].present?)
    end

    # devcontainer.json is JSON-with-comments. Remove comments without
    # touching comment-shaped text inside strings (image URLs are common).
    def strip_json_comments(input)
      output = +""
      in_string = false
      escaped = false
      index = 0
      while index < input.length
        char = input[index]
        following = input[index + 1]
        if in_string
          output << char
          if escaped
            escaped = false
          elsif char == "\\"
            escaped = true
          elsif char == '"'
            in_string = false
          end
        elsif char == '"'
          in_string = true
          output << char
        elsif char == "/" && following == "/"
          index += 2
          index += 1 while index < input.length && input[index] != "\n"
          output << "\n" if index < input.length
        elsif char == "/" && following == "*"
          index += 2
          index += 1 while index + 1 < input.length && input[index, 2] != "*/"
          index += 1
        else
          output << char
        end
        index += 1
      end
      output
    end

    def strip_trailing_commas(input)
      output = +""
      in_string = false
      escaped = false
      input.each_char.with_index do |char, index|
        if in_string
          output << char
          if escaped
            escaped = false
          elsif char == "\\"
            escaped = true
          elsif char == '"'
            in_string = false
          end
        elsif char == '"'
          in_string = true
          output << char
        elsif char == "," && input[(index + 1)..].to_s.lstrip.start_with?("}", "]")
          next
        else
          output << char
        end
      end
      output
    end
  end
end
