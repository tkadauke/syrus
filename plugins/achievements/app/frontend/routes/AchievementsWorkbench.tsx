import { useQuery } from "@tanstack/react-query"
import { useEffect, useId, useMemo, useRef, useState } from "react"
import { Link, useLocation } from "react-router-dom"
import { Button } from "@app/components/Button"
import { FilterBar, type FilterSchemaField } from "@app/components/FilterBar"
import { Notice, Page, Pill, Text } from "@app/components/ui"
import { usePageTitle } from "@app/hooks/usePageTitle"
import { useT } from "@app/hooks/useT"
import { ApiError } from "@app/api/client"
import { fetchWorkbenchCatalog, workbenchQueryKey, type WorkbenchDefinition } from "../api/workbench"
import { AchievementBadge } from "../components/AchievementBadge"
import { LockedCard, UnlockedCard } from "../components/AchievementCards"
import {
  AchievementRevealContent,
  AchievementRevealQueue,
  resolveReducedMotion,
  revealMotionClasses,
  usePrefersReducedMotion
} from "../components/AchievementReveal"
import { DiscussDialog } from "../workbench/DiscussDialog"
import { buildFixture, buildStack, FIXTURE_STATES } from "../workbench/fixtures"
import {
  buildFilterLink,
  filterTree,
  matchesFilters,
  MOTION_SETTINGS,
  selectionFromSearch,
  selectionToSearch,
  VIEWPORTS,
  type WorkbenchSelection
} from "../workbench/search"
import { achievementSoundSupport } from "../workbench/soundSupport"

const STACK_SIZE = 3
const CHOICE_BASE = "rounded-[var(--radius-control)] border px-2 py-1 text-xs font-medium"
const CHOICE_ACTIVE = `${CHOICE_BASE} border-brand bg-brand text-on-brand`
const CHOICE_IDLE = `${CHOICE_BASE} border-border bg-surface text-text-secondary hover:bg-surface-raised`
const REVEAL_FRAME = "mx-auto w-full max-w-md rounded-[var(--radius-panel)] bg-surface p-6 text-center shadow-[var(--shadow-panel)]"

function ChoiceLinks<T extends string>({
  label,
  options,
  selected,
  hrefFor,
  labelFor
}: {
  label: string
  options: readonly T[]
  selected: T
  hrefFor: (option: T) => string
  labelFor: (option: T) => string
}) {
  return (
    <nav aria-label={label} className="flex flex-wrap items-center gap-1.5">
      <span className="text-xs font-medium text-text-secondary">{label}</span>
      {options.map((option) => (
        <Link
          aria-current={option === selected ? "true" : undefined}
          className={option === selected ? CHOICE_ACTIVE : CHOICE_IDLE}
          key={option}
          replace
          to={hrefFor(option)}
        >
          {labelFor(option)}
        </Link>
      ))}
    </nav>
  )
}

// The reveal body inside the preview frame. `phase` is the animation phase the
// operator is looking at; "play" runs start -> end through the same transition
// classes the production dialog uses.
function RevealPreview({
  definition,
  reducedMotion,
  replayKey,
  phase
}: {
  definition: WorkbenchDefinition
  reducedMotion: boolean
  replayKey: number
  phase: "start" | "end" | "play"
}) {
  const titleId = useId()
  const descriptionId = useId()
  const unlock = buildFixture(definition, "unlocked").unlock!
  const [entered, setEntered] = useState(phase !== "start")

  useEffect(() => {
    if (phase !== "play" || reducedMotion) return setEntered(phase !== "start")
    setEntered(false)
    const frame = requestAnimationFrame(() => setEntered(true))
    return () => cancelAnimationFrame(frame)
  }, [phase, reducedMotion, replayKey])

  return (
    <div className={`${REVEAL_FRAME} ${revealMotionClasses(reducedMotion, entered)}`} data-phase={entered ? "end" : "start"}>
      <AchievementRevealContent
        ackStatus="idle"
        descriptionId={descriptionId}
        onContinue={() => setEntered(true)}
        onRetry={() => undefined}
        position={1}
        reducedMotion={reducedMotion}
        titleId={titleId}
        total={1}
        unlock={unlock}
      />
    </div>
  )
}

export default function AchievementsWorkbench() {
  const { t } = useT("achievements")
  usePageTitle(t("workbench.title"))
  const location = useLocation()
  const selection = useMemo(() => selectionFromSearch(location.search), [location.search])
  const catalog = useQuery({ queryKey: workbenchQueryKey, queryFn: fetchWorkbenchCatalog, retry: false })
  const previewRef = useRef<HTMLDivElement | null>(null)
  const [phase, setPhase] = useState<"start" | "end" | "play">("end")
  const [replayKey, setReplayKey] = useState(0)
  const [queue, setQueue] = useState<{ key: number; count: number } | null>(null)
  const systemReduced = usePrefersReducedMotion()
  const reducedMotion = resolveReducedMotion(selection.motion, systemReduced)

  const all = catalog.data?.definitions ?? []
  const visible = useMemo(() => all.filter((definition) => matchesFilters(definition, selection.filters)), [all, selection.filters])
  const selected = visible.find((definition) => definition.key === selection.definition) ?? visible[0] ?? null
  const stack = useMemo(() => (queue && selected ? buildStack(queue.count === 1 ? [selected] : visible, queue.count) : []), [queue, selected, visible])

  const filterSchema: FilterSchemaField[] = useMemo(() => {
    const vocabulary = catalog.data?.vocabulary
    const select = (field: string, values: string[] = []): FilterSchemaField => ({
      field,
      label: t(`workbench.filter_${field}`),
      bucket: "select",
      operators: ["is"],
      values: values.map((value) => ({ value, label: value }))
    })
    return [
      select("scope", vocabulary?.scope),
      select("category", vocabulary?.category),
      select("rarity", vocabulary?.rarity),
      select("trigger", vocabulary?.trigger),
      select("visibility", vocabulary?.visibility),
      select("implementation_status", vocabulary?.implementation_status)
    ]
  }, [catalog.data?.vocabulary, t])

  function hrefFor(patch: Partial<WorkbenchSelection>) {
    return `${location.pathname}${selectionToSearch({ ...selection, definition: selected?.key ?? selection.definition, ...patch })}`
  }

  const deepLink = typeof window === "undefined" ? hrefFor({}) : `${window.location.origin}${hrefFor({})}`
  const viewport = VIEWPORTS.find((candidate) => candidate.id === selection.viewport) ?? VIEWPORTS[2]
  const unavailable = catalog.error instanceof ApiError && catalog.error.status === 404

  return (
    <Page.Root gutter="responsive" size="wide">
      <Page.Header>
        <Page.HeadingGroup>
          <Page.Title>{t("workbench.title")}</Page.Title>
          <Page.Description>{t("workbench.description")}</Page.Description>
        </Page.HeadingGroup>
      </Page.Header>

      {catalog.isLoading ? <Text tone="muted">{t("loading")}</Text> : null}
      {unavailable ? <Notice tone="warning">{t("workbench.unavailable")}</Notice> : null}
      {catalog.isError && !unavailable ? (
        <Notice tone="danger">
          <span>{t("workbench.load_failed")}</span>{" "}
          <Button onClick={() => catalog.refetch()} size="sm" variant="secondary">
            {t("reveal_retry")}
          </Button>
        </Notice>
      ) : null}
      {catalog.data?.problems.length ? (
        <Notice tone="warning">
          {t("workbench.registry_problems")}: {catalog.data.problems.join("; ")}
        </Notice>
      ) : null}

      {catalog.data ? (
        <>
          <Page.Nav className="space-y-3">
            <FilterBar
              buildLink={buildFilterLink}
              filter={filterTree(selection.filters)}
              filterSchema={filterSchema}
              pathname={location.pathname}
              search={location.search}
            />
            <Text muted variant="caption">
              {t("workbench.showing", { count: visible.length, total: all.length })}
            </Text>
          </Page.Nav>

          {visible.length === 0 ? <Notice>{t("workbench.no_match")}</Notice> : null}

          {visible.length > 0 ? (
            <div className="grid gap-5 lg:grid-cols-[18rem_minmax(0,1fr)]">
              <nav aria-label={t("workbench.definitions_aria")}>
                <ul className="space-y-1.5">
                  {visible.map((definition) => (
                    <li key={definition.key}>
                      <Link
                        aria-current={definition.key === selected?.key ? "true" : undefined}
                        className={`block rounded-[var(--radius-control)] border px-3 py-2 text-sm ${definition.key === selected?.key ? "border-brand bg-surface-raised" : "border-border bg-surface hover:bg-surface-raised"}`}
                        replace
                        to={hrefFor({ definition: definition.key })}
                      >
                        <span className="block break-all font-medium text-text-primary">{definition.key}</span>
                        <span className="mt-1 flex flex-wrap gap-1">
                          <Pill>{definition.scope}</Pill>
                          <Pill>{definition.rarity}</Pill>
                          <Pill tone={definition.implementation_status === "implemented" ? "success" : "warning"}>
                            {t(`workbench.status_${definition.implementation_status}`)}
                          </Pill>
                        </span>
                      </Link>
                    </li>
                  ))}
                </ul>
              </nav>

              {selected ? (
                <section aria-label={t("workbench.detail_aria", { key: selected.key })} className="min-w-0 space-y-4">
                  <dl className="grid gap-x-4 gap-y-1 text-sm sm:grid-cols-[auto_1fr]">
                    {(
                      [
                        ["scope", selected.scope],
                        ["category", selected.category],
                        ["rarity", selected.rarity],
                        ["trigger", selected.trigger],
                        ["evaluator", selected.evaluator],
                        ["visibility", selected.visibility],
                        ["implementation_status", t(`workbench.status_${selected.implementation_status}`)],
                        ["subjects", selected.subject_kinds.join(", ")],
                        ["version", String(selected.version)]
                      ] as const
                    ).map(([name, value]) => (
                      <div className="contents" key={name}>
                        <dt className="text-text-secondary">{t(`workbench.fact_${name}`)}</dt>
                        <dd className="break-all text-text-primary">{value}</dd>
                      </div>
                    ))}
                  </dl>

                  <div className="space-y-2">
                    <ChoiceLinks
                      hrefFor={(state) => hrefFor({ state })}
                      label={t("workbench.control_state")}
                      labelFor={(state) => t(`workbench.state_${state}`)}
                      options={FIXTURE_STATES}
                      selected={selection.state}
                    />
                    <ChoiceLinks
                      hrefFor={(id) => hrefFor({ viewport: id })}
                      label={t("workbench.control_viewport")}
                      labelFor={(id) => t(`workbench.viewport_${id}`, { width: VIEWPORTS.find((preset) => preset.id === id)?.width })}
                      options={VIEWPORTS.map((preset) => preset.id)}
                      selected={selection.viewport}
                    />
                    <ChoiceLinks
                      hrefFor={(motion) => hrefFor({ motion })}
                      label={t("workbench.control_motion")}
                      labelFor={(motion) => t(`workbench.motion_${motion}`)}
                      options={MOTION_SETTINGS}
                      selected={selection.motion}
                    />
                    <div className="flex flex-wrap items-center gap-2 text-xs text-text-secondary">
                      <span className="font-medium">{t("workbench.control_audio")}</span>
                      {achievementSoundSupport ? (
                        <>
                          <Link aria-current={selection.audio ? "true" : undefined} className="underline" replace to={hrefFor({ audio: !selection.audio })}>
                            {selection.audio ? t("workbench.audio_on") : t("workbench.audio_off")}
                          </Link>
                          {selection.audio ? (
                            <Button onClick={() => achievementSoundSupport?.play(selected.rarity)} size="sm" variant="secondary">
                              {t("workbench.audio_play")}
                            </Button>
                          ) : null}
                        </>
                      ) : (
                        <span>{t("workbench.audio_unsupported")}</span>
                      )}
                    </div>
                  </div>

                  <div className="flex flex-wrap items-center gap-2">
                    <Button
                      onClick={() => {
                        setPhase("play")
                        setReplayKey((key) => key + 1)
                      }}
                      size="sm"
                      variant="secondary"
                    >
                      {t("workbench.replay_phases")}
                    </Button>
                    <Button aria-pressed={phase === "start"} onClick={() => setPhase("start")} size="sm" variant="secondary">
                      {t("workbench.phase_start")}
                    </Button>
                    <Button aria-pressed={phase === "end"} onClick={() => setPhase("end")} size="sm" variant="secondary">
                      {t("workbench.phase_end")}
                    </Button>
                    <Button onClick={() => setQueue({ key: Date.now(), count: 1 })} size="sm" variant="secondary">
                      {t("workbench.play_reveal")}
                    </Button>
                    <Button onClick={() => setQueue({ key: Date.now(), count: STACK_SIZE })} size="sm" variant="secondary">
                      {t("workbench.play_stack", { count: STACK_SIZE })}
                    </Button>
                    <DiscussDialog
                      input={{
                        definition: selected,
                        fixtureState: selection.state,
                        viewport: { id: viewport.id, width: viewport.width },
                        motion: selection.motion,
                        audio: { supported: Boolean(achievementSoundSupport), enabled: Boolean(achievementSoundSupport) && selection.audio },
                        deepLink
                      }}
                      previewRef={previewRef}
                    />
                  </div>

                  <div className="overflow-x-auto">
                    <div
                      aria-label={t("workbench.preview_aria", { width: viewport.width })}
                      className="mx-auto space-y-4 rounded-[var(--radius-control)] border border-dashed border-border bg-surface p-3"
                      data-testid="workbench-preview"
                      ref={previewRef}
                      style={{ width: `${viewport.width}px` }}
                    >
                      <div className="flex items-end gap-3" data-testid="workbench-badges">
                        {(["sm", "md", "lg"] as const).map((size) => (
                          <AchievementBadge
                            category={selected.category}
                            key={size}
                            rarity={selected.rarity}
                            scope={selected.scope}
                            size={size}
                            state={selection.state === "locked" ? (selected.visibility === "hidden" ? "hidden" : "locked") : "unlocked"}
                          />
                        ))}
                      </div>
                      <ul className="grid gap-3">
                        {(() => {
                          const fixture = buildFixture(selected, selection.state)
                          return fixture.unlock ? (
                            <UnlockedCard busy={false} onAcknowledge={() => undefined} onReplay={() => undefined} unlock={fixture.unlock} />
                          ) : (
                            <LockedCard locked={fixture.locked} />
                          )
                        })()}
                      </ul>
                      <RevealPreview definition={selected} phase={phase} reducedMotion={reducedMotion} replayKey={replayKey} />
                    </div>
                  </div>
                </section>
              ) : null}
            </div>
          ) : null}
        </>
      ) : null}

      {queue && selected ? (
        <AchievementRevealQueue
          acknowledge={async () => undefined}
          key={queue.key}
          motion={selection.motion}
          onFinished={() => setQueue(null)}
          reveals={stack}
        />
      ) : null}
    </Page.Root>
  )
}
