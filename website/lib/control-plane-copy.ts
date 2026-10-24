import type { Locale } from "./locales.ts"

const en = {
  pipelineLabel: "Syrus control plane showing intake, workflow, review, and landing state",
  pipelineTitle: "workflow control plane",
  sidebar: ["Jobs", "Workflows", "Credentials", "Review", "Landing"],
  pipelineHeading: "Browser review and CI repair",
  pipelinePath: "issue to workflow to pull request",
  ready: "ready to land",
  stages: [
    ["Intake", "GitHub issue"],
    ["Workflow", "Codex run"],
    ["Review", "2 notes"],
    ["Landing", "approved"]
  ],
  eyebrow: "The deterministic harness around agent work",
  heroLead: "Agents write code.",
  heroAccent: "Syrus lands work.",
  heroBody:
    "Claude Code, Codex, Muse Code, Antigravity, and skills can all produce meaningful changes. Syrus adds the control plane around them: durable Jobs, typed Workflows, credential gates, review debt, operator UI, CI repair, and landing policy.",
  compare: "Compare the harness",
  plugins: "Explore plugins",
  chips: ["Self-hosted", "Provider-neutral", "GitHub-native", "Human-gated landing"],
  comparisonEyebrow: "Control plane comparison",
  comparisonTitle: "The agent session is powerful. The system around it makes the work durable.",
  comparisonSubtitle:
    "Syrus does not assume agents are helpless without tools. It gives teams a repeatable place for state, permissions, review, repair, and landing to live after the model turn ends.",
  rawTitle: "Raw agent session",
  rawState: "ephemeral",
  rawRows: [
    "Session context lives in chat, shell history, or a local transcript.",
    "Tool calls and credentials depend on whatever the session was handed.",
    "Review feedback is prose the agent must reinterpret later.",
    "Retry, rebase, repair, and merge policy remain manual coordination."
  ],
  syrusTitle: "Syrus harness",
  syrusState: "durable",
  syrusRows: [
    "Durable Jobs, Workflows, Steps, and Runs preserve every attempt.",
    "Credential gates scope GitHub, model provider, browser, and plugin access.",
    "Review Notes stay attached to diffs, files, and follow-up work.",
    "The operator UI, CI repair loop, and landing queue move work to merge."
  ],
  capabilitiesEyebrow: "Bundled control-plane capabilities",
  capabilitiesTitle: "Plugins add hands; Syrus keeps the lifecycle coherent.",
  capabilitiesSubtitle:
    "Adapters, browser context, source providers, review surfaces, and operational briefings plug into the same Job model instead of becoming separate side channels.",
  cards: [
    {
      title: "Provider adapters",
      eyebrow: "Claude · Codex · Muse · Antigravity",
      body: "Syrus can route work to multiple coding-agent backends while keeping the surrounding workflow, transcript, and policy model consistent."
    },
    {
      title: "Credential Store",
      eyebrow: "Scoped access",
      body: "Agents receive bounded credentials for the task at hand, with operator-visible state instead of ad hoc secrets in a prompt window."
    },
    {
      title: "Source plugins",
      eyebrow: "Issue intake",
      body: "GitHub issues, PR feedback, chats, schedules, and plugin-owned sources all enter the same durable Job pipeline."
    },
    {
      title: "Review Notes",
      eyebrow: "Diff-anchored debt",
      body: "Feedback becomes structured, file-aware work the system can track, apply, and repair without losing reviewer intent."
    },
    {
      title: "Browser and previews",
      eyebrow: "Visual context",
      body: "Preview and browser plugins give agents inspectable product state while keeping the evidence attached to the work record."
    },
    {
      title: "Insights and briefings",
      eyebrow: "Operational memory",
      body: "Syrus turns runs, costs, failures, and recurring patterns into dashboards and briefings the team can act on."
    }
  ],
  statementLead: "Other systems give agents more hands.",
  statementAccent: "Syrus gives the team a control plane",
  statementTail: "for the work those hands produce.",
  statementBody:
    "The result is not just more generated code. It is a tracked path from intent to pull request to approved merge, with the same audit trail and review discipline teams expect from human work.",
  loopEyebrow: "Product loop",
  loopTitle: "One loop from intake to landing.",
  loopSubtitle: "Every entry point runs through the same lifecycle, so operators can see where work is, why it is blocked, and what happens next.",
  loop: [
    { title: "Intake", body: "A labeled issue, chat proposal, schedule, or PR review becomes a tracked Job." },
    { title: "Plan", body: "Syrus scopes work into bounded attempts with provider, repository, and execution requirements." },
    { title: "Execute", body: "The chosen agent works inside an isolated workspace with captured prompts, tools, and diffs." },
    { title: "Review", body: "Checks, reviewer notes, and repair attempts stay attached to the exact work they concern." },
    { title: "Land", body: "Approval triggers rebase, final checks, dependency ordering, and merge policy." }
  ],
  surfaceEyebrow: "Operator surface",
  surfaceTitle: "The UI is not decoration. It is the work ledger.",
  surfaceBody:
    "Jobs, attempts, transcripts, diffs, costs, credentials, checks, and landing state are visible to the team. Agents can keep moving, but the operator never loses the thread.",
  docs: "Read what Syrus is"
} as const

const de = {
  pipelineLabel: "Syrus-Steuerzentrale mit Eingang, Workflow, Review und Landing-Status",
  pipelineTitle: "Workflow-Steuerzentrale",
  sidebar: ["Jobs", "Workflows", "Zugangsdaten", "Review", "Landing"],
  pipelineHeading: "Browser-Review und CI-Reparatur",
  pipelinePath: "vom Issue über den Workflow zum Pull Request",
  ready: "bereit zum Landen",
  stages: [
    ["Eingang", "GitHub-Issue"],
    ["Workflow", "Codex-Lauf"],
    ["Review", "2 Hinweise"],
    ["Landing", "freigegeben"]
  ],
  eyebrow: "Die deterministische Steuerung rund um Agentenarbeit",
  heroLead: "Agenten schreiben Code.",
  heroAccent: "Syrus landet Arbeit.",
  heroBody:
    "Claude Code, Codex, Muse Code, Antigravity und Skills können wertvolle Änderungen erzeugen. Syrus ergänzt die Steuerzentrale: dauerhafte Jobs, typisierte Workflows, begrenzte Zugangsdaten, Review-Schulden, Operator-Oberfläche, CI-Reparatur und Landing-Regeln.",
  compare: "System vergleichen",
  plugins: "Plugins entdecken",
  chips: ["Selbst gehostet", "Anbieterneutral", "GitHub-nativ", "Landing durch Menschen freigegeben"],
  comparisonEyebrow: "Vergleich der Steuerzentrale",
  comparisonTitle: "Die Agentensitzung ist leistungsfähig. Das System darum macht die Arbeit dauerhaft.",
  comparisonSubtitle:
    "Syrus nimmt nicht an, dass Agenten ohne Werkzeuge hilflos sind. Es gibt Teams einen wiederholbaren Ort für Status, Berechtigungen, Review, Reparatur und Landing nach dem Modelllauf.",
  rawTitle: "Rohe Agentensitzung",
  rawState: "flüchtig",
  rawRows: [
    "Sitzungskontext lebt im Chat, Shell-Verlauf oder lokalen Transkript.",
    "Werkzeugaufrufe und Zugangsdaten hängen von den Vorgaben der Sitzung ab.",
    "Review-Feedback ist Text, den der Agent später neu deuten muss.",
    "Wiederholung, Rebase, Reparatur und Merge bleiben manuelle Koordination."
  ],
  syrusTitle: "Syrus-System",
  syrusState: "dauerhaft",
  syrusRows: [
    "Dauerhafte Jobs, Workflows, Steps und Läufe bewahren jeden Versuch.",
    "Zugangsschranken begrenzen GitHub-, Modellanbieter-, Browser- und Plugin-Zugriff.",
    "Review-Hinweise bleiben an Diffs, Dateien und Folgearbeit gebunden.",
    "Operator-Oberfläche, CI-Reparaturschleife und Landing Queue bringen Arbeit zum Merge."
  ],
  capabilitiesEyebrow: "Mitgelieferte Steuerungsfunktionen",
  capabilitiesTitle: "Plugins geben zusätzliche Hände; Syrus hält den Lebenszyklus zusammen.",
  capabilitiesSubtitle:
    "Adapter, Browser-Kontext, Quellen, Review-Oberflächen und Betriebsberichte fügen sich in dasselbe Job-Modell statt neue Nebenkanäle zu bilden.",
  cards: [
    {
      title: "Anbieteradapter",
      eyebrow: "Claude · Codex · Muse · Antigravity",
      body: "Syrus verteilt Arbeit auf mehrere Coding-Agenten und hält Workflow, Transkript und Regeln einheitlich."
    },
    {
      title: "Zugangsdaten-Speicher",
      eyebrow: "Begrenzter Zugriff",
      body: "Agenten erhalten begrenzte Zugangsdaten für ihre Aufgabe; der Status bleibt für dich sichtbar statt als improvisiertes Geheimnis im Prompt."
    },
    {
      title: "Quellen-Plugins",
      eyebrow: "Arbeitsaufnahme",
      body: "GitHub-Issues, PR-Feedback, Chats, Zeitpläne und Plugin-Quellen münden in dieselbe dauerhafte Job-Pipeline."
    },
    {
      title: "Review-Hinweise",
      eyebrow: "Am Diff verankert",
      body: "Feedback wird strukturierte, dateibezogene Arbeit, die Syrus verfolgen, anwenden und reparieren kann, ohne die Absicht zu verlieren."
    },
    {
      title: "Browser und Vorschauen",
      eyebrow: "Visueller Kontext",
      body: "Vorschau- und Browser-Plugins geben Agenten prüfbaren Produktstatus; die Belege bleiben am Arbeitsdatensatz."
    },
    {
      title: "Erkenntnisse und Berichte",
      eyebrow: "Betriebswissen",
      body: "Syrus macht aus Läufen, Kosten, Fehlern und Mustern Dashboards und Berichte, auf die dein Team reagieren kann."
    }
  ],
  statementLead: "Andere Systeme geben Agenten mehr Hände.",
  statementAccent: "Syrus gibt dem Team eine Steuerzentrale",
  statementTail: "für die Arbeit dieser Hände.",
  statementBody:
    "Das Ergebnis ist nicht nur mehr erzeugter Code, sondern ein nachvollziehbarer Weg von der Absicht über den Pull Request zum freigegebenen Merge — mit Prüfpfad und Review-Disziplin wie bei menschlicher Arbeit.",
  loopEyebrow: "Produktablauf",
  loopTitle: "Eine Schleife vom Eingang bis zum Landing.",
  loopSubtitle: "Jeder Einstieg folgt demselben Lebenszyklus. Du siehst, wo Arbeit steht, warum sie blockiert ist und was als Nächstes passiert.",
  loop: [
    { title: "Eingang", body: "Ein markiertes Issue, ein Chat-Vorschlag, ein Zeitplan oder PR-Review wird zum Job." },
    { title: "Plan", body: "Syrus begrenzt Versuche mit Anbieter-, Repository- und Ausführungsanforderungen." },
    { title: "Ausführen", body: "Der gewählte Agent arbeitet isoliert; Prompts, Werkzeuge und Diffs werden erfasst." },
    { title: "Review", body: "Prüfungen, Hinweise und Reparaturversuche bleiben an der betroffenen Arbeit." },
    { title: "Landen", body: "Die Freigabe startet Rebase, letzte Prüfungen, Abhängigkeitsordnung und Merge-Regeln." }
  ],
  surfaceEyebrow: "Operator-Oberfläche",
  surfaceTitle: "Die Oberfläche ist kein Schmuck. Sie ist das Arbeitsbuch.",
  surfaceBody:
    "Jobs, Versuche, Transkripte, Diffs, Kosten, Zugangsdaten, Prüfungen und Landing-Status sind für dein Team sichtbar. Agenten arbeiten weiter, ohne dass du den Faden verlierst.",
  docs: "Was Syrus ist (Englisch)"
} as const

const dictionaries = { en, de }
export function controlPlaneFor(locale: Locale): typeof en {
  const copy = dictionaries[locale as keyof typeof dictionaries]
  if (!copy) throw new Error(`No published control-plane dictionary for locale: ${locale}`)
  return copy as unknown as typeof en
}
