import type { ComponentType } from "react"
import { readInitialBootstrap, type SlugReferenceType } from "../api/bootstrap"
import { pluginSlugPreviewCardComponentForPrefix, pluginSlugPreviewCardPrefixes, type PluginSlugPreviewCardProps } from "../pluginSlugPreviewCards"

export type SlugReferenceRegistryEntry = {
  prefix: string
  type: string
  displayLabel: string
  copyable: boolean
  linkable: boolean
  previewAvailable: boolean
  linkifiesGeneratedText: boolean
  hrefTemplate: string | null
  mobileInteractionHints: Record<string, string>
  pluginPreviewComponent: ComponentType<PluginSlugPreviewCardProps> | null
}

let testRegistryEntries: SlugReferenceRegistryEntry[] | null = null

export function slugReferenceRegistryEntries() {
  if (testRegistryEntries) return testRegistryEntries

  const entries = readInitialBootstrap()?.slug_refs?.types ?? []
  return entries.map(registryEntryFromPayload)
}

export function slugReferenceRegistryEntryForPrefix(prefix: string) {
  const normalizedPrefix = prefix.toUpperCase()
  return slugReferenceRegistryEntries().find((entry) => entry.prefix === normalizedPrefix) ?? null
}

export function registeredPluginSlugPreviewCardPrefixes() {
  const registeredPrefixes = new Set(slugReferenceRegistryEntries().map((entry) => entry.prefix))
  return pluginSlugPreviewCardPrefixes().filter((prefix) => registeredPrefixes.has(prefix))
}

export function hrefForSlugReference(entry: SlugReferenceRegistryEntry, id: number) {
  if (!entry.linkable || !entry.hrefTemplate) return null

  return entry.hrefTemplate.replace(":id", String(id))
}

export function setSlugReferenceRegistryForTests(entries: SlugReferenceRegistryEntry[] | null) {
  testRegistryEntries = entries
}

export function registryEntryFromPayload(entry: SlugReferenceType): SlugReferenceRegistryEntry {
  const prefix = entry.prefix.toUpperCase()

  return {
    prefix,
    type: entry.type,
    displayLabel: entry.display_label,
    copyable: entry.copyable,
    linkable: entry.linkable,
    previewAvailable: entry.preview_available,
    linkifiesGeneratedText: entry.linkifies_generated_text,
    hrefTemplate: entry.href_template,
    mobileInteractionHints: entry.mobile_interaction_hints,
    pluginPreviewComponent: pluginSlugPreviewCardComponentForPrefix(prefix)
  }
}
