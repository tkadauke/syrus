class RepoDeploymentStagesReader
  CONFIG_FILE = SyrusYml::CONFIG_FILE
  CACHE_TTL = 5.minutes
  @cache_mutex = Mutex.new
  @process_cache = {}

  Result = Data.define(:stages, :source, :note) do
    def enabled?
      stages.any?
    end
  end

  def self.for_repository(repository, cached: true)
    return new(repository: repository, user: repository.user).resolve unless cached

    key = cache_key(repository)
    return new(repository: repository, user: repository.user).resolve unless key

    fetch_process_cache(key, now: Time.current) do
      new(repository: repository, user: repository.user).resolve
    end
  end

  def self.clear_cache!(repository = nil)
    @cache_mutex.synchronize do
      if repository
        key = cache_key(repository)
        @process_cache.delete(key) if key
      else
        @process_cache = {}
      end
    end
  end

  def self.cache_key(repository)
    return unless repository&.id

    [ repository.id, repository.default_branch.to_s ]
  end
  private_class_method :cache_key

  def self.fetch_process_cache(key, now:)
    entry = @cache_mutex.synchronize do
      cached = @process_cache[key]
      cached if cached && cached[:expires_at] > now
    end
    return entry[:value] if entry

    value = yield
    @cache_mutex.synchronize do
      @process_cache[key] = { value: value, expires_at: now + CACHE_TTL }
    end
    value
  end
  private_class_method :fetch_process_cache

  def initialize(repository:, user:)
    @repository = repository
    @user = user
  end

  def resolve
    loaded = RepoDefaultBranchSyrusYml.new(repository: repository, user: user).resolve
    return disabled(source: loaded.source, note: loaded.note) unless loaded.loaded?

    stages = loaded.config.deployment_stages
    return disabled(source: ".syrus.yml", note: "no deployment_stages configured") if stages.empty?

    Result.new(stages: stages, source: ".syrus.yml", note: nil)
  end

  private

  attr_reader :repository, :user

  def disabled(source:, note:)
    Result.new(stages: [], source: source, note: note)
  end
end
