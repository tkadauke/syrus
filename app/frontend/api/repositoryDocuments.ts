import { deleteJson, getJson, postForm } from "./client"
import type { RepositoryTab } from "./repositories"

export type RepositoryDocumentsRepository = {
  id: number
  slug: string
  repository_path: string
}

export type RepositoryDocument = {
  id: number
  kind: string
  title: string
  google_doc_url: string | null
  filename: string | null
  content_type: string | null
  byte_size: number | null
  uploaded_by: string | null
  created_at: string
  file_path: string | null
}

export type RepositoryDocumentsPayload = {
  repository: RepositoryDocumentsRepository
  can_write: boolean
  tabs: RepositoryTab[]
  documents: RepositoryDocument[]
  pagination: { page: number; per_page: number; total: number; total_pages: number }
  message?: string
}

export type RepositoryDocumentInput = {
  kind: "file" | "google_doc"
  title: string
  google_docs_url: string
  file: File | null
}

export const REPOSITORY_DOCUMENT_ACCEPTED_FILE_CONTENT_TYPES = [
  "text/plain",
  "text/markdown",
  "text/x-markdown",
  "text/html",
  "text/css",
  "text/javascript",
  "application/pdf",
  "image/png",
  "image/jpeg",
  "image/gif",
  "image/webp",
  "image/svg+xml"
]

export function fetchRepositoryDocuments(repositoryId: string, page = 1) {
  return getJson<RepositoryDocumentsPayload>(`/api/v1/app/repositories/${repositoryId}/documents?page=${page}`)
}

export function createRepositoryDocument(repositoryId: number, values: RepositoryDocumentInput) {
  const formData = new FormData()
  formData.append("repository_document[kind]", values.kind)
  formData.append("repository_document[title]", values.title)
  if (values.kind === "google_doc") {
    formData.append("repository_document[google_docs_url]", values.google_docs_url)
  }
  if (values.kind === "file" && values.file) {
    formData.append("repository_document[file]", values.file)
  }

  return postForm<{ document: RepositoryDocument; message: string }>(`/api/v1/app/repositories/${repositoryId}/documents`, formData)
}

export function deleteRepositoryDocument(id: number) {
  return deleteJson<{ id: number; message: string }>(`/api/v1/app/repository_documents/${id}`)
}
