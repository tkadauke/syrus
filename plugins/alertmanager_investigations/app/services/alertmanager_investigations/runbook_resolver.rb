module AlertmanagerInvestigations
  class RunbookResolver
    Result = Data.define(:repository, :ref, :path, :content)

    def self.call(...) = new(...).call

    def initialize(url)
      @url = url.to_s
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

      content = RepositoryContent.for(repository)
      revision = content.resolve(location.ref)
      blob = content.read(revision, location.path)
      Result.new(repository: repository, ref: revision.ref || location.ref, path: location.path, content: blob.text)
    rescue RepositoryContent::NotFound
      nil
    rescue RepositoryContent::Unavailable, RepositoryContent::Unsupported, RepositoryContent::UnknownRevision => e
      Rails.logger.warn("[AlertmanagerInvestigations] runbook unavailable for #{@url}: #{e.class}: #{e.message}")
      nil
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
