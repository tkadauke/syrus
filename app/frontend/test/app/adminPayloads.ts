export function currentAdminQueueFilter() {
  return { and: [{ field: "queue_name", op: "is", value: "runs" }] }
}

export function adminQueuePayloadWithSavedFolder(folderFilter: Record<string, unknown>) {
  return {
    filter: currentAdminQueueFilter(),
    controls: {
      filter_schema: [
        {
          field: "queue_name",
          label: "Queue",
          bucket: "enum",
          operators: ["is"],
          values: [
            { value: "runs", label: "Runs" },
            { value: "chat", label: "Chat" }
          ]
        }
      ]
    },
    active_smart_folder_id: 10,
    smart_folders: [
      {
        id: 10,
        name: "Run repairs",
        position: 2,
        kind: "user_defined",
        subject_type: "admin_queue",
        visibility: "user_defined",
        count: 0,
        active: true,
        filter: folderFilter,
        path: "/admin/queue/active?smart_folder_id=10"
      }
    ],
    jobs: []
  }
}

export function adminQueuePayloadFromSearch(params: URLSearchParams) {
  return {
    ...adminQueuePayloadWithSavedFolder(currentAdminQueueFilter()),
    active_smart_folder_id: params.get("smart_folder_id") === "10" ? 10 : null,
    filter: filterFromSearch(params, currentAdminQueueFilter())
  }
}

export function currentAdminProcessFilter() {
  return { and: [{ field: "state", op: "is", value: "running" }] }
}

export function adminProcessesPayloadWithSavedFolder(folderFilter: Record<string, unknown>) {
  return {
    filter: currentAdminProcessFilter(),
    controls: {
      filter_schema: [
        {
          field: "state",
          label: "State",
          bucket: "enum",
          operators: ["is"],
          values: [
            { value: "running", label: "Running" },
            { value: "finished", label: "Finished" }
          ]
        }
      ]
    },
    active_smart_folder_id: 11,
    smart_folders: [
      {
        id: 11,
        name: "Live agents",
        position: 3,
        kind: "user_defined",
        subject_type: "spawned_process",
        visibility: "user_defined",
        count: 0,
        active: true,
        filter: folderFilter,
        path: "/admin/processes?smart_folder_id=11"
      }
    ],
    running_total: 0,
    total: 0,
    pagination: {
      page: 1,
      per_page: 100,
      total: 0,
      total_pages: 1,
      has_previous_page: false,
      has_next_page: false,
      previous_page: null,
      next_page: null,
      first_item: 0,
      last_item: 0
    },
    sort: { column: "started_at", direction: "desc" },
    processes: []
  }
}

export function adminProcessesPayloadFromSearch(params: URLSearchParams) {
  return {
    ...adminProcessesPayloadWithSavedFolder(currentAdminProcessFilter()),
    active_smart_folder_id: params.get("smart_folder_id") === "11" ? 11 : null,
    filter: filterFromSearch(params, currentAdminProcessFilter())
  }
}

export function currentAdminUserFilter() {
  return { and: [{ field: "gh_rate", op: "is", value: "low" }] }
}

export function adminUsersPayloadWithSavedFolder(folderFilter: Record<string, unknown>) {
  return {
    filters: { gh_rate: "low" },
    filter: currentAdminUserFilter(),
    controls: {
      filter_schema: [
        {
          field: "gh_rate",
          label: "GH rate",
          bucket: "enum",
          operators: ["is"],
          values: [
            { value: "low", label: "Low (<10%)" },
            { value: "exhausted", label: "Exhausted" }
          ]
        }
      ]
    },
    count: 0,
    active_smart_folder_id: 12,
    smart_folders: [
      {
        id: 12,
        name: "Low rate users",
        position: 4,
        kind: "user_defined",
        subject_type: "admin_user",
        visibility: "user_defined",
        count: 0,
        active: true,
        filter: folderFilter,
        path: "/admin/users?smart_folder_id=12"
      }
    ],
    pagination: {
      page: 1,
      per_page: 100,
      total: 0,
      total_pages: 1,
      has_previous_page: false,
      has_next_page: false,
      previous_page: null,
      next_page: null,
      first_item: 0,
      last_item: 0
    },
    sort: { column: "email", direction: "asc" },
    users: []
  }
}

export function adminUsersPayloadFromSearch(params: URLSearchParams) {
  return {
    ...adminUsersPayloadWithSavedFolder(currentAdminUserFilter()),
    active_smart_folder_id: params.get("smart_folder_id") === "12" ? 12 : null,
    filter: filterFromSearch(params, currentAdminUserFilter())
  }
}

export function filterFromSearch(params: URLSearchParams, fallback: Record<string, unknown>) {
  const encoded = params.get("q")
  if (!encoded) return fallback

  const base64 = encoded.replace(/-/g, "+").replace(/_/g, "/")
  const padded = base64.padEnd(Math.ceil(base64.length / 4) * 4, "=")
  return JSON.parse(decodeURIComponent(escape(window.atob(padded)))) as Record<string, unknown>
}
