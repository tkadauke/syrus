import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";

const output = path.join(process.cwd(), "out");
const english = fs.readFileSync(path.join(output, "index.html"), "utf8");

assert.match(english, /<html[^>]*lang="en"/);
assert.equal(fs.existsSync(path.join(output, "en")), false, "canonical English must remain unprefixed");
assert.equal(fs.existsSync(path.join(output, "de")), false, "unpublished German pages must not be exported");
assert.equal(fs.existsSync(path.join(output, "la")), false, "unpublished Latin pages must not be exported");
