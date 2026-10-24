import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { allPosts, findPost, formatPostDate } from "./blog";

const tempDirs: string[] = [];

function makeBlogRoot(files: Record<string, string>): string {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "syrus-blog-test-"));
  tempDirs.push(dir);
  for (const [name, content] of Object.entries(files)) {
    fs.writeFileSync(path.join(dir, name), content);
  }
  return dir;
}

function post(title: string, date: string, body: string): string {
  return `---\ntitle: ${title}\ndescription: About ${title}\ndate: ${date}\n---\n\n${body}\n`;
}

afterEach(() => {
  for (const dir of tempDirs.splice(0)) {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

describe("allPosts", () => {
  it("parses front matter and strips the date prefix from the slug", () => {
    const root = makeBlogRoot({
      "2026-10-28-introducing-syrus.md": post("Syrus is out", "2026-10-28", "# Syrus is out\n\nHello **world**."),
    });

    const posts = allPosts(root);

    expect(posts).toHaveLength(1);
    expect(posts[0]).toMatchObject({
      slug: "introducing-syrus",
      href: "/blog/introducing-syrus",
      title: "Syrus is out",
      description: "About Syrus is out",
      date: "2026-10-28",
    });
    expect(posts[0].html).toContain("<strong>world</strong>");
  });

  it("sorts newest first and ignores non-markdown files", () => {
    const root = makeBlogRoot({
      "2026-09-01-older.md": post("Older", "2026-09-01", "old"),
      "2026-10-28-newer.md": post("Newer", "2026-10-28", "new"),
      "notes.txt": "not a post",
    });

    expect(allPosts(root).map((p) => p.slug)).toEqual(["newer", "older"]);
  });

  it("returns an empty list when the content directory does not exist", () => {
    expect(allPosts(path.join(os.tmpdir(), "syrus-blog-does-not-exist"))).toEqual([]);
  });
});

describe("findPost", () => {
  it("finds a post by slug and returns null for unknown slugs", () => {
    const root = makeBlogRoot({
      "2026-10-28-introducing-syrus.md": post("Syrus is out", "2026-10-28", "body"),
    });

    expect(findPost("introducing-syrus", root)?.title).toBe("Syrus is out");
    expect(findPost("nope", root)).toBeNull();
  });
});

describe("formatPostDate", () => {
  it("formats ISO dates for display and passes through invalid values", () => {
    expect(formatPostDate("2026-10-28")).toBe("October 28, 2026");
    expect(formatPostDate("")).toBe("");
    expect(formatPostDate("someday")).toBe("someday");
  });
});
