import { useEffect } from "react"
import { readInitialBootstrap } from "../api/bootstrap"
import { disableChunkWarmup, startChunkWarmup } from "../lib/chunkWarmup"
import { ADMIN_CHUNK_GROUP } from "./routeChunks"

/**
 * Starts background chunk warm-up after the first commit. Rendered after
 * StartupRenderMarker, whose layout effect marks `react_commit`; passive
 * effects run after every layout effect of the same commit, so warm-up can
 * never start before that milestone or join the startup download.
 *
 * Signed-out visitors warm nothing, and only admins warm admin pages. The Vite
 * dev server compiles modules on request, so warming there would transform the
 * whole app on every page load; development skips it.
 */
export function ChunkWarmupStarter() {
  useEffect(() => {
    if (import.meta.env.MODE === "development") {
      disableChunkWarmup("dev_server")
      return
    }
    const user = readInitialBootstrap()?.current_user
    if (!user) {
      disableChunkWarmup("signed_out")
      return
    }
    startChunkWarmup({ skipGroups: user.admin ? [] : [ADMIN_CHUNK_GROUP] })
  }, [])

  return null
}
