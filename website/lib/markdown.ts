function escapeHtml(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function escapeAttribute(value: string): string {
  return escapeHtml(value).replaceAll("'", "&#39;");
}

function slugify(value: string): string {
  return value
    .toLowerCase()
    .replace(/`([^`]+)`/g, "$1")
    .replace(/[^a-z0-9\s-]/g, "")
    .trim()
    .replace(/\s+/g, "-");
}

function inline(markdown: string): string {
  let html = escapeHtml(markdown);

  html = html.replace(/`([^`]+)`/g, (_match, code: string) => `<code>${code}</code>`);
  html = html.replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>");
  html = html.replace(/\[([^\]]+)\]\(([^)]+)\)/g, (_match, text: string, href: string) => {
    const safeHref = escapeAttribute(href);
    const external = /^https?:\/\//.test(href)
      ? ' target="_blank" rel="noreferrer"'
      : "";

    return `<a href="${safeHref}"${external}>${text}</a>`;
  });

  return html;
}

const HEADING_PATTERN = /^(#{1,6})\s+(.+)$/;

function isTableSeparator(line: string): boolean {
  return /^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?\s*$/.test(line);
}

function tableCells(line: string): string[] {
  return line
    .trim()
    .replace(/^\|/, "")
    .replace(/\|$/, "")
    .split("|")
    .map((cell) => cell.trim());
}

function renderTable(lines: string[], index: number): { html: string; next: number } {
  const headers = tableCells(lines[index]);
  const rows: string[][] = [];
  let cursor = index + 2;

  while (cursor < lines.length && lines[cursor].includes("|") && lines[cursor].trim() !== "") {
    rows.push(tableCells(lines[cursor]));
    cursor += 1;
  }

  const head = headers.map((cell) => `<th>${inline(cell)}</th>`).join("");
  const body = rows
    .map((row) => `<tr>${row.map((cell) => `<td>${inline(cell)}</td>`).join("")}</tr>`)
    .join("");

  return {
    html: `<div class="doc-table-wrap"><table><thead><tr>${head}</tr></thead><tbody>${body}</tbody></table></div>`,
    next: cursor,
  };
}

function renderList(lines: string[], index: number, ordered: boolean): { html: string; next: number } {
  const items: string[] = [];
  let cursor = index;
  const pattern = ordered ? /^\s*\d+\.\s+(.+)$/ : /^\s*[-*]\s+(.+)$/;

  while (cursor < lines.length) {
    const match = lines[cursor].match(pattern);
    if (!match) break;
    items.push(`<li>${inline(match[1])}</li>`);
    cursor += 1;
  }

  const tag = ordered ? "ol" : "ul";
  return { html: `<${tag}>${items.join("")}</${tag}>`, next: cursor };
}

function renderBlockquote(lines: string[], index: number): { html: string; next: number } {
  const quoteLines: string[] = [];
  let cursor = index;

  while (cursor < lines.length && lines[cursor].startsWith(">")) {
    quoteLines.push(lines[cursor].replace(/^>\s?/, ""));
    cursor += 1;
  }

  return {
    html: `<blockquote>${renderMarkdown(quoteLines.join("\n"))}</blockquote>`,
    next: cursor,
  };
}

function normalizeAdmonitions(markdown: string): string {
  const labels: Record<string, string> = {
    caution: "Caution",
    note: "Note",
    tip: "Tip",
    warning: "Warning",
  };

  return markdown
    .split("\n")
    .map((line) => {
      const open = line.match(/^:::(\w+)/);
      if (open) return `> **${labels[open[1]] || open[1]}**`;
      if (line.trim() === ":::") return "";
      return line;
    })
    .join("\n");
}

export function renderMarkdown(markdown: string): string {
  const lines = normalizeAdmonitions(markdown).replace(/\r\n/g, "\n").split("\n");
  const blocks: string[] = [];
  let cursor = 0;

  while (cursor < lines.length) {
    const line = lines[cursor];
    const trimmed = line.trim();

    if (!trimmed) {
      cursor += 1;
      continue;
    }

    const fence = trimmed.match(/^```(\w+)?/);
    if (fence) {
      const language = fence[1] ? ` data-language="${escapeAttribute(fence[1])}"` : "";
      const code: string[] = [];
      cursor += 1;
      while (cursor < lines.length && !lines[cursor].trim().startsWith("```")) {
        code.push(lines[cursor]);
        cursor += 1;
      }
      cursor += 1;
      blocks.push(`<pre${language}><code>${escapeHtml(code.join("\n"))}</code></pre>`);
      continue;
    }

    const heading = trimmed.match(HEADING_PATTERN);
    if (heading) {
      const level = heading[1].length;
      const text = heading[2].replace(/\s+#*$/, "");
      blocks.push(`<h${level} id="${slugify(text)}">${inline(text)}</h${level}>`);
      cursor += 1;
      continue;
    }

    if (cursor + 1 < lines.length && line.includes("|") && isTableSeparator(lines[cursor + 1])) {
      const rendered = renderTable(lines, cursor);
      blocks.push(rendered.html);
      cursor = rendered.next;
      continue;
    }

    if (/^\s*[-*]\s+/.test(line)) {
      const rendered = renderList(lines, cursor, false);
      blocks.push(rendered.html);
      cursor = rendered.next;
      continue;
    }

    if (/^\s*\d+\.\s+/.test(line)) {
      const rendered = renderList(lines, cursor, true);
      blocks.push(rendered.html);
      cursor = rendered.next;
      continue;
    }

    if (line.startsWith(">")) {
      const rendered = renderBlockquote(lines, cursor);
      blocks.push(rendered.html);
      cursor = rendered.next;
      continue;
    }

    const paragraph: string[] = [];
    while (cursor < lines.length) {
      const current = lines[cursor];
      const currentTrimmed = current.trim();
      const nextIsBlock =
        !currentTrimmed ||
        currentTrimmed.startsWith("```") ||
        HEADING_PATTERN.test(currentTrimmed) ||
        currentTrimmed.startsWith(">") ||
        /^\s*[-*]\s+/.test(current) ||
        /^\s*\d+\.\s+/.test(current) ||
        (cursor + 1 < lines.length && current.includes("|") && isTableSeparator(lines[cursor + 1]));

      if (nextIsBlock) break;
      paragraph.push(currentTrimmed);
      cursor += 1;
    }

    blocks.push(`<p>${inline(paragraph.join(" "))}</p>`);
  }

  return blocks.join("\n");
}
