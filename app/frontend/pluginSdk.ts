export {
  getEagerPluginContributions,
  getPluginContribution,
  getPluginContributions,
  pluginContributionGeneration,
  pluginContributionLoader,
  registerPluginContribution,
  registerPluginContributionPreloader,
  subscribeToPluginContributions
} from "./pluginContributionRegistry"

export type { PluginContribution, PluginContributionChange, PluginContributionKind } from "./pluginContributionRegistry"
export type { AgentProviderConnectPanelProps, PluginAgentProviderConnectPanel } from "./pluginAgentProviderConnectPanels"
export type { PluginChatMessagePresentation, PluginChatMessageProps } from "./pluginChatMessageRenderers"
export type { PluginReviewAnnotationComponentProps, PluginReviewAnnotationSurface } from "./pluginReviewAnnotations"
export type { ReviewContributionProps } from "./pluginReviewContributions"
export type { PluginRuntimeSessionView, PluginRuntimeSessionViewProps, RuntimeSessionViewConnectionState } from "./pluginRuntimeSessionViews"
export type { PluginSlugPreviewCardProps } from "./pluginSlugPreviewCards"
export type { PluginWorkspaceTabProps } from "./pluginWorkspaceTabs"
export { spaLoaderDiagnostics } from "./lib/spaLoaderDiagnostics"
export type { SpaLoaderDiagnosticsSnapshot } from "./lib/spaLoaderDiagnostics"

/** Props shared by host-rendered plugin components. Contribution-specific props may extend this shape. */
export type PluginComponentProps<TPayload = unknown> = {
  pluginName: string
  payload?: TPayload
}
