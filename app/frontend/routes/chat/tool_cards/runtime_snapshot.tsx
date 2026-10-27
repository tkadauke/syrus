import type { ToolCardExample } from "@app/pluginToolCards"
import i18n from "../../../i18n"
import { runtimeToolCardRenderer } from "../runtimeToolCard"

export default runtimeToolCardRenderer("runtime_snapshot")

const PIXEL_PNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="

export const examples: ToolCardExample[] = [
  {
    id: "browser_capture",
    label: i18n.t("chat:runtime_snapshot_example_browser"),
    description: i18n.t("chat:runtime_snapshot_example_browser_description"),
    input: { session_id: 17, options: { target: "main", full_page: true } },
    parsedResult: {
      error: false,
      content: [
        { type: "image", data: PIXEL_PNG, mimeType: "image/png" },
        { type: "text", text: "Browser snapshot captured successfully." }
      ],
      page_url: "https://example.test/settings",
      title: i18n.t("chat:runtime_snapshot_example_page_title"),
      viewport: { width: 1280, height: 720 },
      captured_at: "2026-09-10T12:10:00Z"
    }
  },
  {
    id: "android_stale_frame",
    label: i18n.t("chat:runtime_snapshot_example_stale"),
    description: i18n.t("chat:runtime_snapshot_example_stale_description"),
    input: { session_id: 7 },
    parsedResult: {
      kind: "android_screenshot",
      content_type: "image/png",
      bytes: 48213,
      document_id: 31,
      file_path: "/tmp/runtime-frame.png",
      preview_url: `data:image/png;base64,${PIXEL_PNG}`,
      latest_frame_url: "/api/v1/app/chats/8/runtime_sessions/7/frame",
      latest_frame_at: "2026-09-10T12:11:00Z",
      fallback: true,
      warning: "Device offline; showing the latest available frame."
    }
  }
]
