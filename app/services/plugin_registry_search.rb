class PluginRegistrySearch
  Result = Data.define(:entries, :errors, :stale)

  def initialize(sources: PluginRegistry.sources, client_factory: ->(source) { PluginRegistryClient.new(source:) })
    @sources = sources.select(&:enabled?)
    @client_factory = client_factory
  end

  def search(term = nil)
    results = @sources.to_h { |source| [ source, @client_factory.call(source).search(term) ] }
    Result.new(entries: results.values.flat_map(&:entries),
      errors: results.filter_map { |source, result| [ source.name, result.error ] if result.error }.to_h,
      stale: results.filter_map { |source, result| source.name if result.stale })
  end

  def resolve(name:, version: nil, registry: nil)
    matches = search.entries.select { |entry| entry.name == name && (version.blank? || entry.version == version) }
    matches.select! { |entry| entry.registry_name == registry || entry.registry_id.to_s == registry.to_s } if registry.present?
    raise PluginRegistryClient::Error, "compatible plugin release is not present in an enabled registry: #{name}" if matches.empty?
    candidates = matches.group_by { |entry| entry.version }.max_by { |release, _| Gem::Version.new(release) }.last
    candidates.find(&:registry_canonical) || (candidates.one? ? candidates.first :
      raise(PluginRegistryClient::Error, "plugin release is ambiguous; choose a registry explicitly"))
  end

  def client_for(entry)
    source = @sources.find { |candidate| candidate.name == entry.registry_name && candidate.id == entry.registry_id }
    raise PluginRegistryClient::Error, "plugin registry is no longer enabled: #{entry.registry_name}" unless source

    @client_factory.call(source)
  end
end
