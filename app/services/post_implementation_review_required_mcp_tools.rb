class PostImplementationReviewRequiredMcpTools
  def self.call(job:, workflow:, run:)
    Syrus::Plugin::ReviewContributions.contributions(:post_implementation_review_providers).select do |provider|
      result = Syrus::PluginInvocation.call(
        extension_point: :post_implementation_review_provider, provider:, operation: :review_needed?, on_decline: false
      ) { provider.review_needed?(job: job, trigger_kind: workflow&.trigger_kind || run&.trigger_kind) }
      Syrus::PluginInvocation.value(result)
    end.flat_map do |provider|
      result = Syrus::PluginInvocation.call(
        extension_point: :post_implementation_review_provider, provider:, operation: :required_mcp_tools, on_decline: []
      ) { provider.required_mcp_tools(job: job, workflow: workflow, run: run) }
      Array(Syrus::PluginInvocation.value(result))
    end.map(&:to_s).reject(&:blank?).uniq
  end
end
