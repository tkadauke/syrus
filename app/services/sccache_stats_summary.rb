# Best-effort normalizer over one `sccache --show-stats --stats-format=json`
# capture (see Workflow::SccacheArtifact, EPIC-251). sccache's JSON shape has
# shifted across versions and can report counters either at the top level or
# nested under a `"stats"` key, and `cache_hits`/`cache_misses` can appear as
# a bare integer or as `{"counts" => {"C/C++" => 10, ...}}` (per-language
# totals, summed here). This never raises on an unrecognized shape — it just
# yields nil fields, which the UI renders as "not reported" rather than
# guessing wrong.
class SccacheStatsSummary
  Summary = Data.define(:hits, :misses, :hit_rate, :cache_size, :max_cache_size, :cache_location)

  class << self
    def for(stats)
      return blank_summary unless stats.is_a?(Hash)

      hits = extract_count(stats, "cache_hits")
      misses = extract_count(stats, "cache_misses")

      Summary.new(
        hits: hits,
        misses: misses,
        hit_rate: hit_rate_for(hits, misses),
        cache_size: extract_scalar(stats, "cache_size"),
        max_cache_size: extract_scalar(stats, "max_cache_size"),
        cache_location: extract_scalar(stats, "cache_location")
      )
    end

    private

    def blank_summary
      Summary.new(hits: nil, misses: nil, hit_rate: nil, cache_size: nil, max_cache_size: nil, cache_location: nil)
    end

    def extract_count(stats, key)
      value = stats[key]
      value = stats.dig("stats", key) if value.nil?

      case value
      when Integer then value
      when Hash
        counts = value["counts"]
        counts.is_a?(Hash) ? counts.values.select { |v| v.is_a?(Numeric) }.sum : nil
      end
    end

    def extract_scalar(stats, key)
      value = stats[key]
      value = stats.dig("stats", key) if value.nil?
      value
    end

    def hit_rate_for(hits, misses)
      return nil unless hits.is_a?(Integer) && misses.is_a?(Integer)

      total = hits + misses
      return nil if total.zero?

      (hits.to_f / total * 100).round(1)
    end
  end
end
