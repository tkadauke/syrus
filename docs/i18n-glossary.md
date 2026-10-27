# Core localization glossary

This glossary is the source of truth for recurring Syrus domain terms in the
core English (`en`), German (`de`), and Latin (`la`) catalogs. Use it when
adding or reviewing frontend and server locale entries; grammar may require
inflecting an approved term without changing the underlying product noun.

German uses the informal **du/dein/dir** register and informal imperatives.
Do not mix in formal **Sie/Ihr/Ihnen** forms. **Job**, **Workflow**, and
**Epic** remain English product nouns in German. A **Run** is **Lauf**
(plural **Läufe**).

Latin domain terminology has not been approved. Every Latin entry below is
therefore marked **PENDING LATIN REVIEW**. Existing Latin domain nouns may be
left as they are, but implementation must not normalize, propagate, or replace
them from this table until a competent reviewer approves the relevant term.
Ordinary grammar fixes and removal of accidental English are still allowed
when they do not make a domain-term decision.

| en | de | la | Usage notes |
| --- | --- | --- | --- |
| Job | Job; plural **Jobs** | **PENDING LATIN REVIEW** | A durable thread representing one work item, not an agent's occupational role. Keep the English product noun in German. Latin *munus* is not approved; see the ambiguity note below. |
| Run | Lauf; plural **Läufe** | **PENDING LATIN REVIEW** | One execution attempt owned by a Step. Compounds such as **Agentenlauf** follow the same German decision. |
| Epic | Epic; plural **Epics** | **PENDING LATIN REVIEW** | A coordinated group of Jobs. Keep the English product noun in German. |
| Workflow | Workflow; plural **Workflows** | **PENDING LATIN REVIEW** | One top-level attempt for a Job. Keep the English product noun in German. Do not substitute *Arbeitsablauf* as the product noun. |
| landing | Landing | **PENDING LATIN REVIEW** | The controlled process of bringing approved changes onto the target branch. Preserve **Landing** in compounds such as **Landing-Warteschlange** and **Landing-Blocker**. Do not silently equate it with every generic merge. |
| merge train | Merge-Train | **PENDING LATIN REVIEW** | The ordered integration mechanism for a stack or Epic. Use the hyphenated German compound; this is narrower than a generic merge queue. |
| retry | erneuter Versuch (noun); erneut versuchen / erneut ausführen (verb) | **PENDING LATIN REVIEW** | Choose the German form by UI context. A retry creates or starts another attempt; it is not the same as resuming paused work. |
| Repository | Repository; plural **Repositorys** | **PENDING LATIN REVIEW** | A configured source-code repository. Keep **Repository** when referring to the Syrus resource; use compounds such as **Repository-Einstellungen**. |
| Issue | Issue; plural **Issues** | **PENDING LATIN REVIEW** | A GitHub issue or issue-backed source item. Keep **Issue** for the external product concept; do not broaden it to every problem or error. |
| Polling | Polling | **PENDING LATIN REVIEW** | Periodic outbound checks for repository, Issue, PR, or review changes. Keep **Polling** as the German technical noun; distinguish it from a one-off refresh or recheck. |
| Agent | Agent; plural **Agenten** | **PENDING LATIN REVIEW** | The configured software agent/provider acting on work. Use grammatical German forms such as **Agentenlauf** and **Agentenanbieter** where needed; do not imply a human employment role. |

## Latin `munus` ambiguity

*Munus* can carry senses including duty, office, service, task, or function.
That makes it liable to collapse two concepts Syrus must keep separate: a
**Job** as a durable unit of work and a **role** held by a person or agent.
Its appearance here records the ambiguity only; it is a non-normative
candidate, not permission to introduce or standardize it. A Latin reviewer
must decide whether the concepts need distinct terms and how each term behaves
in actual UI phrases before either usage is approved.

## Competent Latin review checklist

Before removing **PENDING LATIN REVIEW** from any entry, a competent reviewer
must check:

- case required by labels, sentences, commands, and interpolated phrases;
- grammatical number and singular/plural forms, including count-dependent UI
  copy;
- declension, gender, agreement, and defensible macrons or orthography;
- semantic collisions with other Syrus domain terms and ordinary Latin;
- the concrete UI context, including narrow labels, actions, statuses, and
  explanatory prose;
- role-vs-job ambiguity, especially any proposed use of *munus*;
- consistency across frontend JSON, Rails YAML, plugin catalogs, and public
  copy without mechanically replacing context-sensitive wording.

Approval should record the chosen lemma, required inflections, rejected
alternatives, and representative UI examples before implementation normalizes
the catalogs.
