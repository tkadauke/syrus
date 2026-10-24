import type { Locale } from "./locales.ts"
import { entryPoints, features, hero, infraPoints, workflowSteps } from "./site.ts"

const en = {
  hero: {
    ...hero,
    chips: ["MIT open source", "Self-hosted on your infra", "Human review on every merge"],
    demo: "Watch the product demo",
    metric: "Built through its own PR loop",
    metricBody: "of Syrus's merged pull requests were written by Syrus itself.",
    receipts: "Read the receipts",
    docsLanguage: "English",
    taglineTranslation: "“He gives twice who gives quickly.”"
  },
  workflow: {
    eyebrow: "How work flows through Syrus",
    title: "You steer it. Syrus opens the PR. Review stays yours.",
    subtitle:
      "Every goal turns into tracked epics and jobs, so you can see what's in progress, what's in review, and what shipped — and the merge still waits for the review policy you set.",
    roles: { human: "Operator", ai: "Syrus AI", both: "In tandem" },
    steps: workflowSteps
  },
  features: {
    eyebrow: "Why Syrus",
    title: "Leverage AI — with the control an owner needs.",
    subtitle: "More output, real guardrails, and full visibility into what's being built — so you can move faster without gambling on quality.",
    docsLanguage: "English documentation",
    items: features
  },
  entries: {
    eyebrow: "Seven ways in, one execution model",
    title: "However work starts, it's tracked the same way.",
    subtitle:
      "A ticket, a narrated screen recording, a review comment, a failing check, a scheduled chore — each becomes, or updates, the same tracked job, with every attempt on one timeline. Nothing happens off the books.",
    items: entryPoints
  },
  media: {
    eyebrow: "Product demo",
    title: "A narrated screen recording can become the next reviewed PR.",
    subtitle: "The launch walkthrough centers on the video-to-Job flow, then follows that work through tracked execution, review queues, and cost visibility.",
    videoLabel: "Syrus product screencast showing a video walkthrough becoming a tracked Job.",
    captionLabel: "English",
    shots: [
      {
        src: "/media/walkthrough-recording.png",
        title: "Video walkthrough analysis",
        alt: "A Syrus chat view showing a narrated screen recording analyzed into a draft Job."
      },
      {
        src: "/media/epic-merge-train.png",
        title: "Dashboard triage queue",
        alt: "A Syrus dashboard list showing Jobs, workflow status, filters, and review state."
      },
      {
        src: "/media/spending-audit.png",
        title: "Spending and audit trail",
        alt: "A Syrus spending dashboard showing model cost trend and top spend categories."
      }
    ]
  },
  screenshot: {
    dashboardLabel: "Preview of the Syrus jobs dashboard turning issues into pull requests",
    desktopAlt: "The Syrus dashboard turning GitHub issues into pull requests.",
    mobileAlt: "The Syrus app on mobile.",
    jobsLabel: "Jobs",
    jobs: [
      { id: "#412", title: "Add token-bucket rate limiting to the API", meta: "Claude Code · workflow run 3", state: "Implementing", tone: "active" },
      { id: "#409", title: "Fix flaky authentication spec", meta: "PR #128 opened · 2 min ago", state: "PR opened", tone: "pr" },
      { id: "#402", title: "Bump dependencies to latest minor", meta: "PR #126 merged", state: "Merged", tone: "done" },
      { id: "#398", title: "Nightly documentation sweep", meta: "cron · every day 03:00", state: "Scheduled", tone: "idle" },
      { id: "#395", title: "Rebase feature/billing onto main", meta: "deterministic · no conflicts", state: "Rebasing", tone: "active" }
    ],
    status: "poller healthy · 5 jobs · 2 workers idle"
  },
  demo: {
    title: "Run Syrus yourself.",
    accent: "Keep the project open.",
    body: "Download the desktop app: it sets up a complete local Syrus with Docker, or connects to your own instance. The public docs and GitHub repo are the starting point for installation, operations, bug reports, and community contributions.",
    note: "The product video above shows the core loop first: walkthrough to Job, implementation, review, and tracked cost.",
    how: "See how it works",
    points: infraPoints,
    eyebrow: "Open-source onboarding",
    start: "Start from the public project",
    intro:
      "Syrus is an open-source, self-hosted project. Everything you need to evaluate it starts with the release artifacts, documentation, and public issue tracker.",
    links: [
      { label: "Read the docs", body: "Understand the architecture, setup flow, and operating model before you install.", href: "/docs", external: false },
      {
        label: "Open GitHub",
        body: "Browse the MIT-licensed source, file issues, or follow release activity in the public repo.",
        href: "repository",
        external: true
      },
      {
        label: "Getting started",
        body: "Install the desktop app or server, connect GitHub, configure a provider, and land the first pull request.",
        href: "/docs/getting-started",
        external: false
      }
    ],
    docsLanguage: "English",
    noGate: "No account signup, vendor workspace, or product gate: fork it, install it, inspect it, and run it against repositories you control."
  },
  download: {
    back: "← Back to home",
    title: "Download Syrus",
    intro:
      "The Syrus desktop app for macOS sets up a complete local Syrus (Docker included) or connects to an existing self-hosted instance. The build is universal: one download runs natively on both Apple Silicon and Intel Macs.",
    button: "Download",
    latest: "Every download is the latest published release. Looking for a specific version or the release notes?",
    releases: "Browse all releases →"
  }
} as const

const de = {
  hero: {
    eyebrow: "Open-Source-Infrastruktur für KI-Coding-Workflows",
    titleLead: "Zeig Syrus die Aufgabe.",
    titleAccent: "Prüfe den Pull Request, den es öffnet.",
    subtitle:
      "Syrus ist eine selbst gehostete Open-Source-Automatisierung für KI-Coding-Workflows auf GitHub. Issues, Chats und kommentierte Videoaufnahmen werden zu nachvollziehbaren Pull Requests, während Repositories, Zugangsdaten, Prüfungen, Transkripte, Review-Regeln und Merge-Abläufe in deiner Infrastruktur bleiben.",
    chips: ["MIT Open Source", "Selbst gehostet auf deiner Infrastruktur", "Menschliches Review vor jedem Merge"],
    demo: "Produktdemo ansehen",
    metric: "Durch den eigenen PR-Ablauf erstellt",
    metricBody: "der zusammengeführten Pull Requests von Syrus wurden von Syrus selbst geschrieben.",
    receipts: "Nachweise lesen",
    docsLanguage: "Englisch",
    taglineTranslation: "„Doppelt gibt, wer schnell gibt.“"
  },
  workflow: {
    eyebrow: "So läuft Arbeit durch Syrus",
    title: "Du gibst die Richtung vor. Syrus öffnet den PR. Das Review bleibt bei dir.",
    subtitle:
      "Jedes Ziel wird zu nachvollziehbaren Epics und Jobs. Du siehst, was läuft, geprüft wird oder ausgeliefert ist — und der Merge wartet weiterhin auf deine Review-Regeln.",
    roles: { human: "Operator", ai: "Syrus AI", both: "Gemeinsam" },
    steps: [
      {
        who: "human",
        actor: "Operator",
        action: "Ziel festlegen",
        note: "Beschreibe das Ergebnis in einem Syrus-Chat — ein Feature, ein Refactoring oder eine größere Initiative. Syrus liest die ausgewählten Repositories und entwirft den Plan. Erst deine Bestätigung macht daraus Arbeit."
      },
      {
        who: "ai",
        actor: "Syrus AI",
        action: "Epics und Jobs vorschlagen",
        note: "Große Ziele werden zu Epics: nach Abhängigkeiten geordnete Stapel klar begrenzter Jobs, die du annehmen, bearbeiten oder ablehnen kannst, bevor Code entsteht."
      },
      {
        who: "human",
        actor: "Entwickler",
        action: "Arbeit freigeben",
        note: "Du gibst den Plan zur Ausführung frei — oder startest Syrus direkt mit einem Label an einem GitHub-Issue, genau dort, wo dein Code lebt."
      },
      {
        who: "ai",
        actor: "Syrus AI",
        action: "Code schreiben",
        note: "Syrus klont, erstellt Branches und implementiert in isolierten Workspaces — viele Änderungen gleichzeitig, selbst an denselben Dateien. Danach öffnet es einen Pull Request mit Diff und Testplan. Das vollständige Transkript bleibt am Job."
      },
      {
        who: "both",
        actor: "Syrus AI + Entwickler",
        action: "Gemeinsam reviewen",
        note: "Deine Prüfungen — Tests, Lint und Typecheck — bewerten jede Änderung. Ein Fehler schickt den Agenten zurück, bevor der PR geöffnet wird. Syrus beantwortet Review-Kommentare; du bringst das menschliche Urteil ein."
      },
      {
        who: "human",
        actor: "Entwickler",
        action: "Geprüfte Änderungen landen",
        note: "Deine Freigabe steuert den Merge. Syrus rebasiert, prüft den exakten Branch erneut und führt in Abhängigkeitsreihenfolge zusammen. Branch-Schutz wird nie umgangen."
      }
    ]
  },
  features: {
    eyebrow: "Warum Syrus",
    title: "Nutze KI — mit der Kontrolle, die du brauchst.",
    subtitle: "Mehr Ergebnis, echte Leitplanken und volle Sicht auf die entstehende Arbeit — damit du schneller wirst, ohne Qualität zu verspielen.",
    docsLanguage: "Englische Dokumentation",
    items: [
      {
        id: "walkthrough",
        title: "Zeig den Fehler, statt ihn abzutippen",
        body: "Nimm im Chat eine kommentierte Bildschirmaufnahme auf oder lade eine webm-, mp4- oder mov-Datei hoch. Syrus analysiert das Video, erkennt Probleme, Sollverhalten und visuellen Kontext und führt alles in denselben Vorschlags- und Job-Ablauf.",
        href: "/docs/video-walkthroughs"
      },
      {
        id: "leverage",
        title: "Wiederholbare Agenten-Workflows",
        body: "Führe viele Änderungen gleichzeitig auf einer Codebasis aus — auch an denselben Dateien. Jeder Job arbeitet isoliert; laufende Branches werden automatisch rebasiert und geordnete Arbeit landet als gestapelte Pull Requests."
      },
      {
        id: "approve",
        title: "Agentenänderungen mit normalen Review-Regeln",
        body: "Deine Tests, Lints und Typechecks bewerten jede Änderung. Fehler gehen zurück an den Agenten. Danach entscheidet deine Review-Regel über den Merge."
      },
      {
        id: "landing",
        title: "Freigeben — Syrus landet selbst",
        body: "Nach der Freigabe übernimmt die Landing Queue: rebasen, den exakten Branch prüfen und in Abhängigkeitsreihenfolge mergen. Epics landen vollständig grün oder gar nicht."
      },
      {
        id: "visibility",
        title: "Sieh genau, was gebaut wird",
        body: "Ziele werden zu Epics und Jobs. Jeder Versuch behält Transkript, Diff und Review. Dashboards zeigen Queues, Worker, Auslastung und Repository-Durchsatz."
      },
      {
        id: "cost",
        title: "Kenne die Kosten jedes Features",
        body: "Jeder Lauf erfasst seine Kosten. Das Ausgaben-Dashboard schlüsselt KI-Kosten nach Epic, Nutzer und Repository auf."
      },
      {
        id: "keys",
        title: "Behalte die Kontrolle",
        body: "Syrus läuft selbst gehostet. Dein Code geht nur an den Plugin-basierten Modellanbieter deiner Wahl und mit deinen Zugangsdaten. Syrus ruft nur nach außen auf: keine eingehenden Webhooks, kein öffentliches Endpunkt-Risiko."
      }
    ]
  },
  entries: {
    eyebrow: "Sieben Einstiege, ein Ausführungsmodell",
    title: "Egal wie Arbeit beginnt: Sie wird gleich verfolgt.",
    subtitle:
      "Ticket, kommentierte Aufnahme, Review-Kommentar, fehlgeschlagene Prüfung oder geplanter Auftrag — alles wird zum selben nachvollziehbaren Job oder aktualisiert ihn; jeder Versuch steht auf einer Zeitachse.",
    items: [
      { id: "issue", title: "Issue oder Ticket", body: "Ein markiertes GitHub-Issue wird beim nächsten Repository-Abruf zu Job, Branch und Pull Request." },
      {
        id: "feedback",
        title: "PR-Feedback",
        body: "Dein Review-Kommentar löst einen Folge-Commit auf demselben Branch aus; Kommentare des Teams warten auf die Anwendung mit einem Klick."
      },
      { id: "ci", title: "CI-Fehler", body: "Eine fehlgeschlagene Prüfung startet einen begrenzten automatischen Reparaturversuch." },
      {
        id: "walkthrough",
        title: "Videoaufnahme",
        body: "Nimm deinen Bildschirm mit Kommentar im Chat auf. Syrus erkennt Probleme, Sollverhalten und Screenshots, bevor der Agent die Arbeit vorschlägt."
      },
      {
        id: "direct",
        title: "Chat oder direkter Prompt",
        body: "Ein bestätigter Chat-Vorschlag oder direkter Prompt — ohne Ticket, für Routine, Experimente und dringende Arbeit."
      },
      { id: "scheduled", title: "Geplante Aufgabe", body: "Cron- oder Einmalläufe für Abhängigkeiten, Dokumentationspflege und Repository-Hygiene." },
      {
        id: "rebase",
        title: "Rebase",
        body: "Ein nicht mergebarer Branch erhält einen deterministischen Rebase; nur wenn Urteil nötig ist, greift der Agent ein."
      }
    ]
  },
  media: {
    eyebrow: "Produktdemo",
    title: "Aus einer kommentierten Bildschirmaufnahme kann der nächste geprüfte PR werden.",
    subtitle: "Die Einführung zeigt zuerst den Weg vom Video zum Job und folgt ihm dann durch Ausführung, Review-Warteschlangen und Kostentransparenz.",
    videoLabel: "Syrus-Produktvideo: Eine Bildschirmaufnahme wird zu einem nachvollziehbaren Job.",
    captionLabel: "Englisch",
    shots: [
      {
        src: "/media/walkthrough-recording.png",
        title: "Analyse einer Videoaufnahme",
        alt: "Syrus-Chat mit einer kommentierten Bildschirmaufnahme, die als Job-Entwurf analysiert wurde."
      },
      { src: "/media/epic-merge-train.png", title: "Triage-Warteschlange", alt: "Syrus-Dashboard mit Jobs, Workflow-Status, Filtern und Review-Status." },
      { src: "/media/spending-audit.png", title: "Ausgaben und Prüfpfad", alt: "Syrus-Ausgaben-Dashboard mit Modellkostentrend und größten Kostenbereichen." }
    ]
  },
  screenshot: {
    dashboardLabel: "Vorschau des Syrus-Job-Dashboards, das Issues in Pull Requests verwandelt",
    desktopAlt: "Das Syrus-Dashboard verwandelt GitHub-Issues in Pull Requests.",
    mobileAlt: "Die mobile Syrus-Ansicht.",
    jobsLabel: "Jobs",
    jobs: [
      { id: "#412", title: "Token-Bucket-Ratenbegrenzung zur API hinzufügen", meta: "Claude Code · Workflow-Lauf 3", state: "In Umsetzung", tone: "active" },
      { id: "#409", title: "Instabilen Authentifizierungstest reparieren", meta: "PR #128 geöffnet · vor 2 Min.", state: "PR geöffnet", tone: "pr" },
      { id: "#402", title: "Abhängigkeiten auf aktuelle Minor-Versionen anheben", meta: "PR #126 zusammengeführt", state: "Zusammengeführt", tone: "done" },
      { id: "#398", title: "Nächtliche Dokumentationspflege", meta: "Cron · täglich 03:00", state: "Geplant", tone: "idle" },
      { id: "#395", title: "feature/billing auf main rebasen", meta: "deterministisch · keine Konflikte", state: "Rebase läuft", tone: "active" }
    ],
    status: "Poller gesund · 5 Jobs · 2 Worker frei"
  },
  demo: {
    title: "Betreibe Syrus selbst.",
    accent: "Halte das Projekt offen.",
    body: "Die Desktop-App richtet ein vollständiges lokales Syrus samt Docker ein oder verbindet sich mit deiner bestehenden Instanz. Öffentliche Dokumentation und GitHub-Repository sind dein Ausgangspunkt für Installation, Betrieb, Fehlerberichte und Beiträge.",
    note: "Das Produktvideo oben zeigt zuerst den Kernablauf: von der Aufnahme zum Job, über Implementierung und Review bis zu erfassten Kosten.",
    how: "So funktioniert es",
    points: [
      "MIT Open Source und selbst gehostet auf deiner Infrastruktur",
      "Menschliches Review und Freigabe jeder Änderung — nach deinen Regeln",
      "Vollständiges Transkript, Diff und Kosten jedes Laufs",
      "Docker-Installation mit einem Befehl; Kubernetes ist für größere Installationen dokumentiert"
    ],
    eyebrow: "Open-Source-Einstieg",
    start: "Starte beim öffentlichen Projekt",
    intro: "Syrus ist ein selbst gehostetes Open-Source-Projekt. Releases, Dokumentation und der öffentliche Issue-Tracker liefern alles für deine Bewertung.",
    links: [
      { label: "Dokumentation lesen", body: "Lerne Architektur, Einrichtung und Betriebsmodell vor der Installation kennen.", href: "/docs", external: false },
      { label: "GitHub öffnen", body: "Durchsuche den MIT-lizenzierten Quellcode, melde Issues oder verfolge Releases.", href: "repository", external: true },
      {
        label: "Erste Schritte",
        body: "Installiere Desktop-App oder Server, verbinde GitHub, konfiguriere einen Anbieter und lande den ersten Pull Request.",
        href: "/docs/getting-started",
        external: false
      }
    ],
    docsLanguage: "Englisch",
    noGate:
      "Keine Kontoanmeldung, kein Anbieter-Workspace und keine Produktschranke: Forke, installiere und prüfe Syrus und führe es mit Repositories aus, die du kontrollierst."
  },
  download: {
    back: "← Zurück zur Startseite",
    title: "Syrus herunterladen",
    intro:
      "Die Syrus-Desktop-App für macOS richtet ein vollständiges lokales Syrus samt Docker ein oder verbindet sich mit einer bestehenden selbst gehosteten Instanz. Ein universeller Download läuft nativ auf Apple Silicon und Intel-Macs.",
    button: "Herunterladen",
    latest: "Jeder Download ist die neueste veröffentlichte Version. Suchst du eine bestimmte Version oder die Versionshinweise?",
    releases: "Alle Releases ansehen →"
  }
} as const

export type MarketingDictionary = typeof en
export function marketingFor(locale: Locale): MarketingDictionary {
  if (locale === "en") return en
  if (locale === "de") return de as unknown as MarketingDictionary
  throw new Error(`No published marketing dictionary for locale: ${locale}`)
}
