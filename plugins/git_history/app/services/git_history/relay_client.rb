require "net/http"

module GitHistory
  # Fetches git-history reads from a worker pod's internal GitHistory::RelayServer
  # instead of touching local disk — the web process does not share a
  # filesystem with the worker pod(s) that maintain RepositoryBareClone. Used
  # by GitHistory::Commits in place of a direct CommitLog instance.
  #
  # Duck-types CommitLog's public interface (`available?`, `fetch`) so
  # GitHistory::Commits doesn't need to know which one it's holding.
  #
  # A relay that's unreachable degrades the same way an unsynced bare clone
  # does — "not available yet", not a hard error — since CommitLog already
  # treats a missing clone that way.
  class RelayClient
    class Unavailable < StandardError; end

    OPEN_TIMEOUT_SECONDS = 2
    READ_TIMEOUT_SECONDS = 5

    HOST = ENV.fetch("SYRUS_GIT_HISTORY_INTERNAL_HOST", "127.0.0.1")

    def initialize(repository:)
      @repository = repository
    end

    def available?
      parsed = get_json("/repositories/#{@repository.id}/available")
      parsed["available"] == true
    rescue Unavailable
      false
    end

    def fetch(cursor:, limit:)
      parsed = get_json("/repositories/#{@repository.id}/commits", cursor: cursor, limit: limit)
      entries = Array(parsed["entries"]).map(&:symbolize_keys)
      CommitLog::Page.new(entries: entries, has_more: parsed["has_more"] == true)
    rescue Unavailable
      CommitLog::Page.new(entries: [], has_more: false)
    end

    private

    def get_json(path, **query)
      uri = URI::HTTP.build(
        host: HOST,
        port: RelayServer::PORT,
        path: path,
        query: query.compact.presence && URI.encode_www_form(query.compact)
      )

      response = Net::HTTP.start(uri.host, uri.port, open_timeout: OPEN_TIMEOUT_SECONDS, read_timeout: READ_TIMEOUT_SECONDS) do |http|
        http.get(uri.request_uri)
      end

      raise Unavailable, "git history relay returned #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body)
    rescue Errno::ECONNREFUSED, Errno::ETIMEDOUT, Net::OpenTimeout, Net::ReadTimeout, SocketError, JSON::ParserError => e
      raise Unavailable, e.message
    end
  end
end
