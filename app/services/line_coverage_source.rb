# Asks :line_coverage_provider plugins for per-line coverage evidence. Core
# surfaces that display or reason about coverage (diff review, cognitive debt,
# the agent environment snapshot) read through here instead of owning the
# analysis; with no provider, or a provider that declines or raises, there is
# simply no evidence.
module LineCoverageSource
  # Newest repository-wide per-file coverage on the default branch. `data` is
  # { "path.rb" => { "lines_pct" => Float, ... } }.
  FileCoverage = Data.define(:sha, :recorded_at, :data)

  module_function

  def diff_line_statuses(job:, version:, files:)
    each_provider(:diff_line_statuses, {}, job:, version:, files:).each_with_object({}) do |statuses, merged|
      statuses.to_h.each { |path, lines| (merged[path] ||= {}).merge!(lines.to_h) }
    end
  end

  # The first provider's answer wins: there is one repository-wide snapshot.
  def latest_default_branch_files(repository:)
    found = each_provider(:latest_default_branch_files, nil, repository:).compact.first
    return nil unless found

    FileCoverage.new(sha: found[:sha], recorded_at: found[:recorded_at], data: found[:files] || {})
  end

  def agent_context_lines(run:, workspace_path:, repository:)
    each_provider(:agent_context_lines, [], run:, workspace_path:, repository:).flat_map { |lines| Array(lines) }
  end

  def each_provider(operation, default, **arguments)
    Syrus::PluginRegistry.providers_for(:line_coverage_provider).filter_map do |provider|
      next unless provider.respond_to?(operation)

      result = Syrus::PluginInvocation.call(
        extension_point: :line_coverage_provider, provider:, operation:, on_decline: default
      ) { provider.public_send(operation, **arguments) }
      Syrus::PluginInvocation.value(result)
    end
  end
  private_class_method :each_provider
end
