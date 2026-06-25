import { KeyboardEvent, useEffect, useMemo, useRef, useState } from "react"
import { useQuery } from "@tanstack/react-query"

type RepoPickerProps = {
  value?: string
  onChange: (repoSlug: string) => void
  disabled?: boolean
}

export function RepoPicker({ value, onChange, disabled = false }: RepoPickerProps) {
  const [isOpen, setIsOpen] = useState(false)
  const [query, setQuery] = useState("")
  const [lastUsedRepo, setLastUsedRepo] = useState("")
  const wrapperRef = useRef<HTMLDivElement>(null)
  const inputRef = useRef<HTMLInputElement>(null)
  const repositoriesQuery = useQuery({
    queryKey: ["repositories"],
    queryFn: () => window.syrusDesktop.fetchRepositories()
  })
  const repositories = repositoriesQuery.data ?? []
  const selectedRepo = repositories.find((repository) => repository.slug === value) ?? null
  const filteredRepositories = useMemo(() => {
    const normalizedQuery = query.trim().toLowerCase()
    if (normalizedQuery === "") {
      return repositories
    }

    return repositories.filter((repository) => repository.slug.toLowerCase().includes(normalizedQuery))
  }, [query, repositories])

  useEffect(() => {
    let isMounted = true

    window.syrusDesktop.getLastUsedRepo().then((repoSlug) => {
      if (isMounted) {
        setLastUsedRepo(repoSlug)
      }
    })

    return () => {
      isMounted = false
    }
  }, [])

  useEffect(() => {
    if (value || repositories.length === 0) {
      return
    }

    const storedRepo = repositories.find((repository) => repository.slug === lastUsedRepo)
    if (storedRepo) {
      onChange(storedRepo.slug)
    }
  }, [lastUsedRepo, onChange, repositories, value])

  useEffect(() => {
    const closeOnOutsideClick = (event: MouseEvent) => {
      if (!wrapperRef.current?.contains(event.target as Node)) {
        setIsOpen(false)
      }
    }

    document.addEventListener("mousedown", closeOnOutsideClick)
    return () => document.removeEventListener("mousedown", closeOnOutsideClick)
  }, [])

  const selectRepo = (repoSlug: string) => {
    onChange(repoSlug)
    setQuery("")
    setIsOpen(false)
    void window.syrusDesktop.setLastUsedRepo(repoSlug)
  }

  const openPicker = () => {
    if (disabled) {
      return
    }

    setIsOpen(true)
    window.requestAnimationFrame(() => inputRef.current?.focus())
  }

  const handleKeyDown = (event: KeyboardEvent<HTMLInputElement>) => {
    if (event.key === "Escape") {
      setIsOpen(false)
      return
    }

    if (event.key === "Enter" && filteredRepositories.length === 1) {
      event.preventDefault()
      selectRepo(filteredRepositories[0].slug)
    }
  }

  return (
    <div className="repo-picker" ref={wrapperRef}>
      <button
        aria-expanded={isOpen}
        aria-haspopup="listbox"
        className="repo-picker__trigger"
        disabled={disabled}
        onClick={openPicker}
        type="button"
      >
        <span className={selectedRepo ? "repo-picker__value" : "repo-picker__placeholder"}>
          {selectedRepo?.slug ?? "Select repository"}
        </span>
        <span aria-hidden="true" className="repo-picker__chevron">v</span>
      </button>

      {isOpen ? (
        <div className="repo-picker__popover">
          <input
            aria-label="Search repositories"
            className="repo-picker__search"
            onChange={(event) => setQuery(event.target.value)}
            onKeyDown={handleKeyDown}
            placeholder="Filter repositories"
            ref={inputRef}
            type="search"
            value={query}
          />

          <div className="repo-picker__list" role="listbox">
            {repositoriesQuery.isLoading ? (
              <div className="repo-picker__status">Loading repositories...</div>
            ) : repositoriesQuery.isError ? (
              <div className="repo-picker__status">Could not load repositories.</div>
            ) : repositories.length === 0 ? (
              <div className="repo-picker__status">No repositories connected.</div>
            ) : filteredRepositories.length === 0 ? (
              <div className="repo-picker__status">No matching repositories.</div>
            ) : (
              filteredRepositories.map((repository) => (
                <button
                  aria-selected={repository.slug === value}
                  className="repo-picker__option"
                  key={repository.id}
                  onClick={() => selectRepo(repository.slug)}
                  role="option"
                  type="button"
                >
                  <span>{repository.slug}</span>
                  {repository.slug === value ? <span>Selected</span> : null}
                </button>
              ))
            )}
          </div>
        </div>
      ) : null}
    </div>
  )
}
