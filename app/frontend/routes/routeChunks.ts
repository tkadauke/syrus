import { warmableChunk } from "../lib/chunkWarmup"

// One warmable loader per lazily loaded core route module. The priority is the
// background warm-up order (lower first): the pages operators use all day,
// then the rest of the product, then administration, which only admins warm.
// Plugin contributions sit between the product pages and administration; see
// builtInPluginContributions.ts.
//
// Every caller -- React.lazy, the boot-time preload of the current route and
// the warm-up queue -- goes through these loaders, so each chunk is requested
// once.
export const ROUTE_CHUNK_PRIORITY = { primary: 0, secondary: 1, admin: 4 } as const
export const ADMIN_CHUNK_GROUP = "admin"

const primary = { priority: ROUTE_CHUNK_PRIORITY.primary }
const secondary = { priority: ROUTE_CHUNK_PRIORITY.secondary }
const admin = { priority: ROUTE_CHUNK_PRIORITY.admin, group: ADMIN_CHUNK_GROUP }

export const routeChunks = {
  jobDetail: warmableChunk("route:JobDetail", () => import("./JobDetail"), primary),
  chat: warmableChunk("route:Chat", () => import("./Chat"), primary),
  epicDetail: warmableChunk("route:EpicDetail", () => import("./EpicDetail"), primary),
  repositories: warmableChunk("route:Repositories", () => import("./Repositories"), primary),
  repositoryDetail: warmableChunk("route:RepositoryDetail", () => import("./RepositoryDetail"), primary),
  directJobNew: warmableChunk("route:DirectJobNew", () => import("./DirectJobNew"), primary),
  chatSearch: warmableChunk("route:ChatSearch", () => import("./ChatSearch"), primary),
  landingLanes: warmableChunk("route:LandingLanes", () => import("./LandingLanes"), primary),
  permissionInbox: warmableChunk("route:PermissionInbox", () => import("./PermissionInbox"), primary),

  onboarding: warmableChunk("route:Onboarding", () => import("./Onboarding"), secondary),
  epicForm: warmableChunk("route:EpicForm", () => import("./EpicForm"), secondary),
  repositoryForm: warmableChunk("route:RepositoryForm", () => import("./RepositoryForm"), secondary),
  repositorySkillNew: warmableChunk("route:RepositorySkillNew", () => import("./RepositorySkillNew"), secondary),
  repositoryCognitiveDebt: warmableChunk("route:RepositoryCognitiveDebt", () => import("./RepositoryCognitiveDebt"), secondary),
  repositoryDocuments: warmableChunk("route:RepositoryDocuments", () => import("./RepositoryDocuments"), secondary),
  repositoryTargetGraph: warmableChunk("route:RepositoryTargetGraph", () => import("./RepositoryTargetGraph"), secondary),
  profile: warmableChunk("route:Profile", () => import("./Profile"), secondary),
  credentials: warmableChunk("route:Credentials", () => import("./Credentials"), secondary),
  agentSettings: warmableChunk("route:AgentSettings", () => import("./AgentSettings"), secondary),
  preferences: warmableChunk("route:Preferences", () => import("./Preferences"), secondary),
  notificationsSettings: warmableChunk("route:NotificationsSettings", () => import("./NotificationsSettings"), secondary),
  themesSettings: warmableChunk("route:ThemesSettings", () => import("./ThemesSettings"), secondary),
  permissionsSettings: warmableChunk("route:PermissionsSettings", () => import("./PermissionsSettings"), secondary),
  connectedPlatforms: warmableChunk("route:ConnectedPlatforms", () => import("./ConnectedPlatforms"), secondary),
  personalDocuments: warmableChunk("route:PersonalDocuments", () => import("./PersonalDocuments"), secondary),
  tags: warmableChunk("route:Tags", () => import("./Tags"), secondary),
  designSystem: warmableChunk("route:DesignSystem", () => import("./DesignSystem"), secondary),

  adminOverview: warmableChunk("route:AdminOverview", () => import("./AdminOverview"), admin),
  adminQueue: warmableChunk("route:AdminQueue", () => import("./AdminQueue"), admin),
  adminStuck: warmableChunk("route:AdminStuck", () => import("./AdminStuck"), admin),
  adminWorkflowActivity: warmableChunk("route:AdminWorkflowActivity", () => import("./AdminWorkflowActivity"), admin),
  adminWorkUnits: warmableChunk("route:AdminWorkUnits", () => import("./AdminWorkUnits"), admin),
  adminMaintenanceTasks: warmableChunk("route:AdminMaintenanceTasks", () => import("./AdminMaintenanceTasks"), admin),
  adminReconcilerActivity: warmableChunk("route:AdminReconcilerActivity", () => import("./AdminReconcilerActivity"), admin),
  adminBrowserErrors: warmableChunk("route:AdminBrowserErrors", () => import("./AdminBrowserErrors"), admin),
  adminBackendExceptions: warmableChunk("route:AdminBackendExceptions", () => import("./AdminBackendExceptions"), admin),
  adminPlugins: warmableChunk("route:AdminPlugins", () => import("./AdminPlugins"), admin),
  adminPluginServices: warmableChunk("route:AdminPluginServices", () => import("@plugins/plugin_runtime/app/frontend/routes/AdminPluginServices"), {
    ...admin,
    manifestKey: "plugins/plugin_runtime/app/frontend/routes/AdminPluginServices.tsx"
  }),
  adminProcesses: warmableChunk("route:AdminProcesses", () => import("./AdminProcesses"), admin),
  adminMcpToolUsage: warmableChunk("route:AdminMcpToolUsage", () => import("./AdminMcpToolUsage"), admin),
  adminTranscript: warmableChunk("route:AdminTranscript", () => import("./AdminTranscript"), admin),
  adminUsers: warmableChunk("route:AdminUsers", () => import("./AdminUsers"), admin),
  adminTeams: warmableChunk("route:AdminTeams", () => import("./AdminTeams"), admin),
  adminConsole: warmableChunk("route:AdminConsole", () => import("./AdminConsole"), admin),
  adminInstallations: warmableChunk("route:AdminInstallations", () => import("./AdminInstallations"), admin),
  adminGithubApp: warmableChunk("route:AdminGithubApp", () => import("./AdminGithubApp"), admin),
  adminFeatures: warmableChunk("route:AdminFeatures", () => import("./AdminFeatures"), admin),
  retentionSettings: warmableChunk("route:RetentionSettings", () => import("./RetentionSettings"), admin),
  adminInvitations: warmableChunk("route:AdminInvitations", () => import("./AdminInvitations"), admin),
  adminSettings: warmableChunk("route:AdminSettings", () => import("./AdminSettings"), admin)
}
