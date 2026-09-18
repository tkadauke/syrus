import { postJson } from "@app/api/client"

export type ToolCardJobScreenshotInput = {
  name: string
  mimeType: string
  dataUrl: string
}

export type ToolCardJobCreatedPayload = {
  message: string
  redirect_to: string
  job: {
    id: number
    job_path: string
  }
}

export function createToolCardJob(input: { prompt: string; screenshot?: ToolCardJobScreenshotInput | null }) {
  return postJson<ToolCardJobCreatedPayload>("/api/v1/app/admin/tool_card_jobs", {
    prompt: input.prompt,
    ...(input.screenshot
      ? {
          screenshot: {
            name: input.screenshot.name,
            mime_type: input.screenshot.mimeType,
            data: input.screenshot.dataUrl.replace(/^data:[^;]+;base64,/, "")
          }
        }
      : {})
  })
}
