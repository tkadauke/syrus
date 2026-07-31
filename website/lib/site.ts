// Central configuration + copy for the Syrus marketing site.
// NEXT_PUBLIC_* values are inlined at build time; the "|| default" keeps the
// site fully functional with zero configuration.

export const site = {
  name: "Syrus",
  domain: "syrus-ai.dev",

  tagline: "Bis dat qui cito dat.",
  taglineTranslation: "“He gives twice who gives quickly.”",
  taglineAttribution: "— Publilius Syrus",

  contactEmail: process.env.NEXT_PUBLIC_CONTACT_EMAIL || "contact@syrus-ai.dev",

  // The site is static (GitHub Pages), but the demo form still posts to the
  // self-hosted SMTP endpoint on the VM — reachable at its own subdomain since
  // the apex now points at Pages. That endpoint sends CORS headers for this
  // origin; if it's unreachable, the form falls back to a mailto: (see demo.tsx).
  apiBase: process.env.NEXT_PUBLIC_API_BASE || "https://api.syrus-ai.dev",

  build: {
    sha: process.env.NEXT_PUBLIC_GIT_SHA || "dev",
    ref: process.env.NEXT_PUBLIC_GIT_REF || "local",
  },
} as const;

export const hero = {
  eyebrow: "Built for product & project owners",
  titleLead: "Ship more of your roadmap.",
  titleAccent: "Without losing sight of a thing.",
  subtitle:
    "Syrus lets product, project, and application owners put AI to work from goal to merged pull request — turning conversations into tracked epics and tickets, running many changes on your codebase at once, and keeping a human review on every merge. You ship more each sprint, you see exactly what's being built and what it cost, and the guardrails keep AI's speed from becoming AI's mess.",
} as const;

// The human + AI team workflow — who does what, start to finish.
export const workflowSteps = [
  {
    who: "human",
    actor: "Leads & PMs",
    action: "Set the goal",
    note: "Describe the outcome in a Syrus chat — a feature, a refactor, a whole initiative. Syrus reads your repositories and drafts the plan. Nothing becomes work until you confirm it.",
  },
  {
    who: "ai",
    actor: "Syrus AI",
    action: "Proposes epics & tickets",
    note: "Big goals become epics: dependency-ordered stacks of scoped tickets — “Jobs”, in Syrus — that your team can accept, edit, or reject before any code is written.",
  },
  {
    who: "human",
    actor: "Developers",
    action: "Green-light the work",
    note: "A developer releases the plan for execution — or triggers Syrus directly with a label on a GitHub issue, right where your code already lives.",
  },
  {
    who: "ai",
    actor: "Syrus AI",
    action: "Writes the code",
    note: "Clones, branches, and implements in an isolated workspace — many changes in flight at once, even on the same files — then opens a pull request with the diff and a step-by-step test plan. The full transcript stays on the job record.",
  },
  {
    who: "both",
    actor: "Syrus AI + developer",
    action: "Review in tandem",
    note: "Your own checks — tests, lint, typecheck — grade every change, and a red result sends the agent back before the PR even opens. Syrus answers review comments; your developer brings the judgment machines can't.",
  },
  {
    who: "human",
    actor: "Developers",
    action: "Ship world-class code",
    note: "Human approval gates the merge — self-review, two-person, or a designated final say: your policy. Once approved, Syrus lands it for you — rebased, re-checked on the exact branch, merged in dependency order. Branch protection, never bypassed.",
  },
] as const;

// The product pillars — framed for the owner who wants leverage with control.
export const features = [
  {
    id: "leverage",
    title: "Multiply your output",
    body: "Run many changes on one codebase at once — even changes that touch the same files. Every job works in its own isolated workspace, in-flight branches are rebased against each other automatically, and ordered work ships as stacked pull requests that land in sequence.",
  },
  {
    id: "approve",
    title: "AI speed, without the AI mess",
    body: "Your own checks — tests, lint, typecheck — grade every change, and a red result sends the agent back to fix it before a PR ever opens. Then human approval gates the merge, per the review policy you set. AI's velocity never turns into hallucinated logic slipping into production.",
  },
  {
    id: "landing",
    title: "Approve it — it lands itself",
    body: "After sign-off, the landing queue takes over: rebase, re-run your checks on the exact branch about to merge, then merge in dependency order. Epics land as one green unit or not at all — no half-merged features on your main branch.",
  },
  {
    id: "visibility",
    title: "See exactly what's being built",
    body: "Goals become tracked epics and tickets, and every attempt keeps its full transcript, diff, and review — an append-only record of who asked for what and exactly what the agent did. Operational dashboards track queues, workers, and host pressure so failures have context.",
  },
  {
    id: "cost",
    title: "Know what every feature cost",
    body: "Every run records what it spent. A spending dashboard breaks AI cost down by epic, person, and repository — so you know what each feature actually cost to build, not just that it shipped.",
  },
  {
    id: "keys",
    title: "Stay in control, on your terms",
    body: "Self-hosted on your infrastructure, and your code goes only to the model provider you choose — Claude or Codex, on your own credentials. Syrus only ever calls out: no inbound webhooks, no public endpoint to expose. Your issues, reviews, and merges stay in GitHub.",
  },
] as const;

// Every way work can start — one execution model, several entry points.
export const entryPoints = [
  {
    id: "issue",
    title: "Issue or ticket",
    body: "A labeled issue becomes a tracked job, a branch, and a pull request.",
  },
  {
    id: "feedback",
    title: "PR feedback",
    body: "Your review comment triggers a follow-up commit on the same branch; teammates' comments queue for one-click apply.",
  },
  {
    id: "ci",
    title: "CI failure",
    body: "A failing check kicks off a bounded, automatic repair attempt.",
  },
  {
    id: "direct",
    title: "Chat or direct prompt",
    body: "A confirmed chat proposal or a direct prompt from your team, no ticket needed — chores, experiments, urgent work.",
  },
  {
    id: "scheduled",
    title: "Scheduled task",
    body: "Cron or one-shot runs for dependency chores, docs sweeps, hygiene.",
  },
  {
    id: "rebase",
    title: "Rebase",
    body: "An unmergeable branch gets a deterministic rebase — the agent steps in only if judgment is needed.",
  },
] as const;

export const infraPoints = [
  "More shipped each sprint, no new hires",
  "Human review and approval on every change — your policy",
  "Full transcript, diff, and cost record for every run",
  "Self-hosted — one-command Docker install, Kubernetes when you scale",
] as const;
