module AlertmanagerInvestigations
  class RunbookResolver
    MAX_RUNBOOK_BYTES = 32.kilobytes
    OPT_IN_KEY = "autonomous-investigation"

    Result = Data.define(:repository, :ref, :path, :content)

    def self.call(...) = new(...).call

    def initialize(url, configuration: Configuration.current)
      @url = url.to_s
      @configuration = configuration
    end

    def call
      RunbookLocation.candidates(@url).each do |location|
        resolved = resolve_location(location)
        return resolved if resolved
      end

      nil
    end

    private

    def resolve_location(location)
      repository = Repository.active.find_by(owner: location.owner, name: location.name)
      return nil unless repository
      return nil unless location.ref == repository.default_branch
      return nil unless safe_path?(location.path)
      return nil unless @configuration.runbook_allowed?(repository, location.path)

      content = RepositoryContent.for(repository)
      revision = content.resolve(repository.default_branch)
      blob = content.read(revision, location.path, max_bytes: MAX_RUNBOOK_BYTES)
      return nil if blob.truncated
      return nil unless opted_in?(blob.text)

      Result.new(repository: repository, ref: revision.ref || location.ref, path: location.path, content: blob.text)
    rescue RepositoryContent::NotFound
      nil
    rescue RepositoryContent::Unavailable, RepositoryContent::Unsupported, RepositoryContent::UnknownRevision => e
      Rails.logger.warn("[AlertmanagerInvestigations] runbook unavailable for #{@url}: #{e.class}: #{e.message}")
      nil
    end

    def opted_in?(text)
      match = text.match(/\A---\s*\r?\n(.*?)\r?\n---\s*(?:\r?\n|\z)/m)
      return false unless match

      frontmatter = YAML.safe_load(match[1], permitted_classes: [], aliases: false)
      frontmatter.is_a?(Hash) && frontmatter[OPT_IN_KEY] == true
    rescue Psych::Exception
      false
    end

    def safe_path?(path)
      segments = path.to_s.split("/")
      segments.present? && segments.none? { |segment| segment.blank? || segment == "." || segment == ".." || segment.include?("\0") }
    end
  end

  RunbookLocation = Data.define(:owner, :name, :ref, :path) do
    def self.candidates(url)
      uri = URI.parse(url)
      from_github_blob(uri) || from_raw_github(uri) || []
    rescue URI::InvalidURIError
      []
    end

    def self.from_github_blob(uri)
      return unless uri.scheme == "https" && uri.host == "github.com"

      owner, name, marker, *rest = path_segments(uri)
      return unless owner.present? && name.present? && marker == "blob"

      split_candidates(owner: owner, name: name, rest: rest)
    end

    def self.from_raw_github(uri)
      return unless uri.scheme == "https" && uri.host == "raw.githubusercontent.com"

      owner, name, *rest = path_segments(uri)
      return unless owner.present? && name.present?

      split_candidates(owner: owner, name: name, rest: rest)
    end

    def self.path_segments(uri)
      uri.path.to_s.split("/").reject(&:blank?).map { |segment| URI.decode_www_form_component(segment) }
    end

    def self.split_candidates(owner:, name:, rest:)
      return [] if rest.length < 2

      (1...rest.length).map do |split_at|
        new(
          owner: owner,
          name: name,
          ref: rest.first(split_at).join("/"),
          path: rest.drop(split_at).join("/")
        )
      end
    end
  end
end
