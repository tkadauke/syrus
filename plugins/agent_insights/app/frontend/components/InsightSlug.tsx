import { CopyableSlug } from "@app/components/CopyableSlug"
import { SlugReferenceCard } from "@app/components/SlugHoverCard"
import { slugReferenceRegistryEntryForPrefix } from "@app/lib/slugReferenceRegistry"

export function InsightSlug({ slug, className = "text-xs" }: { slug: string; className?: string }) {
  const entry = slugReferenceRegistryEntryForPrefix("INSIGHT")
  const id = Number(slug.replace(/^INSIGHT-/i, ""))

  const control = <CopyableSlug className={className} slug={slug} />
  if (!entry || !Number.isFinite(id)) return control

  return (
    <SlugReferenceCard entry={entry} id={id}>
      {control}
    </SlugReferenceCard>
  )
}
