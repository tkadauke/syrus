module AlertmanagerInvestigations
  class RunbookResolver
    Result = Data.define(:repository, :ref, :path, :content)

    def self.call(...) = new(...).call

    def initialize(url)
      @url = url.to_s
    end

    def call
      location = RunbookLocation.parse(@url)
      return nil unless location

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
    GITHUB_BLOB = %r{
      \Ahttps://github\.com/(?<owner>[^/]+)/(?<name>[^/]+)/blob/(?<ref>[^/]+)/(?<path>.+)\z
    }x.freeze
    RAW_GITHUB = %r{
      \Ahttps://raw\.githubusercontent\.com/(?<owner>[^/]+)/(?<name>[^/]+)/(?<ref>[^/]+)/(?<path>.+)\z
    }x.freeze

    def self.parse(url)
      uri = URI.parse(url)
      from_github_blob(uri) || from_raw_github(uri)
    rescue URI::InvalidURIError
      nil
    end

    def self.from_github_blob(uri)
      match = uri.to_s.match(GITHUB_BLOB)
      new(**match.named_captures.symbolize_keys) if match
    end

    def self.from_raw_github(uri)
      match = uri.to_s.match(RAW_GITHUB)
      new(**match.named_captures.symbolize_keys) if match
    end
  end
end
