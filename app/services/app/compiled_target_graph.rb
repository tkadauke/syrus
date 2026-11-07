module App
  class CompiledTargetGraph
    CACHE_VERSION = 1
    Result = Data.define(:graph, :diagnostics)

    def self.for(repository:, revision:, path:)
      Rails.cache.fetch(cache_key(repository: repository, revision: revision)) do
        Result.new(
          graph: TargetGraph::Compiler.compile(path),
          diagnostics: TargetGraph::Compiler.diagnose(path)
        )
      end
    end

    def self.cache_key(repository:, revision:)
      [ "target-graph", CACHE_VERSION, repository.id, revision ]
    end
  end
end
