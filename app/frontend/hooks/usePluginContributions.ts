import { useSyncExternalStore } from "react"
import { pluginContributionGeneration, subscribeToPluginContributions } from "../pluginContributionRegistry"

export function usePluginContributions() {
  return useSyncExternalStore(subscribeToPluginContributions, pluginContributionGeneration, pluginContributionGeneration)
}
