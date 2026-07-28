import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import type { FormEvent, ReactNode } from "react"
import { useState } from "react"
import { Link } from "react-router-dom"
import { useT } from "../hooks/useT"
import { usePageTitle } from "../hooks/usePageTitle"
import { NoticeToast } from "../components/NoticeToast"
import {
  createTag,
  deleteTag,
  fetchTags,
  updateTag,
  type TagPaletteColor,
  type TagRow,
  type TagsPayload
} from "../api/tags"
import { errorMessage } from "../lib/errorMessage"

const queryKey = ["tags"] as const

export function Tags() {
  const { t } = useT("settings")
  usePageTitle(t("tags.heading"))
  const [notice, setNotice] = useState<string | null>(null)
  const tags = useQuery({
    queryKey,
    queryFn: fetchTags
  })

  return (
    <main aria-label={t("aria_tags")} className="mx-auto max-w-6xl space-y-6 p-6">
      <header>
        <h1 className="text-2xl font-semibold text-gray-900 dark:text-gray-100">{t('tags.heading')}</h1>
        <p className="mt-1 text-sm text-gray-500 dark:text-gray-400">{t('tags.description')}</p>
      </header>

      <NoticeToast message={notice} onDismiss={() => setNotice(null)} />
      {tags.isPending ? <PanelMessage>{t('tags.loading')}</PanelMessage> : null}
      {tags.isError ? <TagsError error={tags.error} /> : null}
      {tags.isSuccess ? <TagsView onNotice={setNotice} payload={tags.data} /> : null}
    </main>
  )
}

function TagsView({ payload, onNotice }: { payload: TagsPayload; onNotice: (message: string | null) => void }) {
  const { t } = useT("settings")
  return (
    <>
      <CreateTagForm onNotice={onNotice} palette={payload.palette} />
      <TagsTable onNotice={onNotice} palette={payload.palette} tags={payload.tags} />
    </>
  )
}

function CreateTagForm({ palette, onNotice }: { palette: TagPaletteColor[]; onNotice: (message: string | null) => void }) {
  const { t } = useT("settings")
  const queryClient = useQueryClient()
  const [name, setName] = useState("")
  const [color, setColor] = useState("gray")
  const create = useMutation({
    mutationFn: () => createTag({ name, color }),
    onSuccess: (payload) => {
      queryClient.setQueryData(queryKey, payload)
      setName("")
      setColor("gray")
      onNotice(payload.message || t('tags.created'))
    }
  })

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    onNotice(null)
    create.mutate()
  }

  return (
    <section className="rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-4">
      <h2 className="text-sm font-semibold text-gray-900 dark:text-gray-100">{t('tags.create')}</h2>
      <form className="mt-3 flex flex-wrap items-end gap-3" onSubmit={submit}>
        <label className="block text-xs font-medium uppercase text-gray-500 dark:text-gray-400" htmlFor="new-tag-name">
          {t('tags.field_name')}
          <input
            id="new-tag-name"
            className="mt-1 block rounded border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-900 px-2 py-1.5 text-sm normal-case text-gray-700 dark:text-gray-300"
            onChange={(event) => setName(event.target.value)}
            required
            type="text"
            value={name}
          />
        </label>
        <label className="block text-xs font-medium uppercase text-gray-500 dark:text-gray-400" htmlFor="new-tag-color">
          {t('tags.field_color')}
          <select
            id="new-tag-color"
            className="mt-1 block rounded border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-900 px-2 py-1.5 text-sm normal-case text-gray-700 dark:text-gray-300"
            onChange={(event) => setColor(event.target.value)}
            value={color}
          >
            {palette.map((option) => (
              <option key={option.key} value={option.key}>{option.label}</option>
            ))}
          </select>
        </label>
        <button
          className="rounded bg-indigo-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-indigo-500 disabled:cursor-not-allowed disabled:bg-indigo-300"
          disabled={create.isPending}
          type="submit"
        >
          {create.isPending ? t('tags.creating') : t('tags.create_btn')}
        </button>
      </form>
      {create.isError ? <p className="mt-3 text-sm text-red-700 dark:text-red-300" role="alert">{errorMessage(create.error, "Unable to create tag.")}</p> : null}
    </section>
  )
}

function TagsTable({ tags, palette, onNotice }: { tags: TagRow[]; palette: TagPaletteColor[]; onNotice: (message: string | null) => void }) {
  const { t } = useT("settings")
  return (
    <section className="overflow-hidden rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900">
      <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-700">
        <thead className="bg-gray-50 dark:bg-gray-800 text-left text-xs font-medium uppercase text-gray-500 dark:text-gray-400">
          <tr>
            <th className="px-4 py-2">{t('tags.col_tag')}</th>
            <th className="px-4 py-2">{t('tags.col_jobs')}</th>
            <th className="px-4 py-2">{t('tags.col_rename')}</th>
            <th className="px-4 py-2"><span className="sr-only">Actions</span></th>
          </tr>
        </thead>
        <tbody className="divide-y divide-gray-100 dark:divide-gray-800 text-sm">
          {tags.length === 0 ? (
            <tr><td className="px-4 py-6 text-center text-gray-500 dark:text-gray-400" colSpan={4}>{t('tags.empty')}</td></tr>
          ) : tags.map((tag) => (
            <TagTableRow key={tag.id} onNotice={onNotice} palette={palette} tag={tag} />
          ))}
        </tbody>
      </table>
    </section>
  )
}

function TagTableRow({ tag, palette, onNotice }: { tag: TagRow; palette: TagPaletteColor[]; onNotice: (message: string | null) => void }) {
  const { t } = useT("settings")
  const queryClient = useQueryClient()
  const [name, setName] = useState(tag.name)
  const [color, setColor] = useState(tag.color)
  const update = useMutation({
    mutationFn: () => updateTag(tag.id, { name, color }),
    onSuccess: (payload) => {
      queryClient.setQueryData(queryKey, payload)
      onNotice(payload.message || t('tags.tag_updated'))
    }
  })
  const destroy = useMutation({
    mutationFn: () => deleteTag(tag.id),
    onSuccess: (payload) => {
      queryClient.setQueryData(queryKey, payload)
      onNotice(payload.message || t('tags.deleted'))
    }
  })

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    onNotice(null)
    update.mutate()
  }

  return (
    <tr>
      <td className="px-4 py-3"><TagChip palette={palette} tag={tag} /></td>
      <td className="px-4 py-3 text-gray-600 dark:text-gray-400">{tag.jobs_count}</td>
      <td className="px-4 py-3">
        <form className="flex flex-wrap items-center gap-2" onSubmit={submit}>
          <input
            aria-label={t('tags.name_for', { name: tag.name })}
            className="w-48 rounded border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-900 px-2 py-1.5 text-sm text-gray-700 dark:text-gray-300"
            onChange={(event) => setName(event.target.value)}
            required
            type="text"
            value={name}
          />
          <select
            aria-label={t('tags.color_for', { name: tag.name })}
            className="rounded border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-900 px-2 py-1.5 text-sm text-gray-700 dark:text-gray-300"
            onChange={(event) => setColor(event.target.value)}
            value={color}
          >
            {palette.map((option) => (
              <option key={option.key} value={option.key}>{option.label}</option>
            ))}
          </select>
          <button
            className="rounded bg-gray-900 px-3 py-1.5 text-sm font-medium text-white hover:bg-gray-800 disabled:cursor-not-allowed disabled:bg-gray-400"
            disabled={update.isPending}
            type="submit"
          >
            {update.isPending ? t('tags.saving') : t('tags.save')}
          </button>
        </form>
        {update.isError ? <p className="mt-2 text-xs text-red-700 dark:text-red-300" role="alert">{errorMessage(update.error, "Unable to update tag.")}</p> : null}
      </td>
      <td className="px-4 py-3 text-right">
        <button
          className="text-sm text-red-600 dark:text-red-300 underline hover:no-underline disabled:cursor-not-allowed disabled:text-red-300 dark:disabled:text-red-500"
          disabled={destroy.isPending}
          onClick={() => {
            if (window.confirm(t('tags.confirm_delete', { name: tag.name }))) {
              onNotice(null)
              destroy.mutate()
            }
          }}
          type="button"
        >
          {destroy.isPending ? t('tags.deleting') : t('tags.delete')}
        </button>
        {destroy.isError ? <p className="mt-2 text-xs text-red-700 dark:text-red-300" role="alert">{errorMessage(destroy.error, "Unable to delete tag.")}</p> : null}
      </td>
    </tr>
  )
}

function TagChip({ tag, palette }: { tag: TagRow; palette: TagPaletteColor[] }) {
  const { t } = useT("settings")
  const colors = tagColors(tag.color, palette)

  return (
    <span className="inline-flex items-center rounded px-2 py-0.5 text-xs font-medium" style={{ backgroundColor: colors.bg, color: colors.text }}>
      {tag.name}
    </span>
  )
}

function TagsError({ error }: { error: Error }) {
  const { t } = useT("settings")
  return <PanelMessage tone="error">{errorMessage(error, "Unable to load tags.")}</PanelMessage>
}

function PanelMessage({ children, tone = "muted" }: { children: ReactNode; tone?: "muted" | "error" }) {
  const { t } = useT("settings")
  return <div className={`p-4 text-sm ${tone === "error" ? "text-red-700 dark:text-red-300" : "text-gray-600 dark:text-gray-400"}`}>{children}</div>
}

function tagColors(color: string, palette: TagPaletteColor[]) {
  const match = palette.find((option) => option.key === color)
  if (match) return { bg: match.bg, text: match.text }
  if (/^#[0-9a-fA-F]{6}$/.test(color)) return { bg: color, text: readableTextColor(color) }
  const fallback = palette.find((option) => option.key === "gray")
  return fallback ? { bg: fallback.bg, text: fallback.text } : { bg: "#f3f4f6", text: "#374151" }
}

function readableTextColor(hex: string) {
  const value = hex.replace("#", "")
  const red = parseInt(value.slice(0, 2), 16)
  const green = parseInt(value.slice(2, 4), 16)
  const blue = parseInt(value.slice(4, 6), 16)
  const luminance = (0.299 * red + 0.587 * green + 0.114 * blue) / 255
  return luminance > 0.62 ? "#111827" : "#ffffff"
}

