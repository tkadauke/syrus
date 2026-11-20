# frozen_string_literal: true

require "rails_helper"

RSpec.describe "runtime plugin invocation boundaries" do
  # Tool handlers intentionally raise through MCP's dispatch wrapper so it can
  # produce the protocol error response; the discovery calls are isolated.
  DIRECT_TELEMETRY_ALLOWLIST = %w[
    app/services/mcp/sidecar.rb
    lib/syrus/plugin/preview_provider.rb
  ].freeze

  it "keeps direct plugin timing calls behind the invocation boundary" do
    paths = Dir[Rails.root.join("app/**/*.rb"), Rails.root.join("lib/**/*.rb")]
    offenders = paths.filter_map do |pathname|
      path = Pathname(pathname).relative_path_from(Rails.root).to_s
      next if path == "lib/syrus/plugin_invocation.rb"
      next if DIRECT_TELEMETRY_ALLOWLIST.include?(path)

      contents = File.readlines(pathname)
      lines = contents.each_index.filter_map do |index|
        index + 1 if contents[index].include?("PerformanceLogging.plugin_call")
      end
      "#{path}:#{lines.join(',')}" if lines.any?
    end

    expect(offenders).to be_empty, <<~MESSAGE
      Runtime provider calls must use Syrus::PluginInvocation.call instead of
      calling the timing seam directly. Offenders: #{offenders.join('; ')}
    MESSAGE
  end
end
