module Evals
  # Append-only JSONL history so an operator can compare eval runs over
  # time (e.g. "did this SKILL.md wording change make the pressure
  # scenario pass more reliably?"). One line per scenario result; never
  # rewritten in place.
  module ResultStore
    HISTORY_PATH = File.expand_path("../../results/history.jsonl", __dir__).freeze

    def self.append(result, path: HISTORY_PATH)
      FileUtils.mkdir_p(File.dirname(path))
      File.open(path, "a") { |f| f.puts(JSON.generate(result.to_h)) }
    end

    def self.history(scenario_slug: nil, path: HISTORY_PATH)
      return [] unless File.exist?(path)

      File.readlines(path).filter_map do |line|
        line = line.strip
        next if line.empty?

        row = JSON.parse(line)
        next if scenario_slug && row["scenario_slug"] != scenario_slug

        row
      end
    end
  end
end
