import fs from "node:fs";
import path from "node:path";

const root = process.cwd();
const excluded = new Set([".git", ".context", "node_modules", "scripts/dewey"]);
const markdownFiles = [];

function walk(directory) {
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    const relative = path.relative(root, path.join(directory, entry.name));
    if (entry.isDirectory()) {
      if (!excluded.has(relative) && !excluded.has(entry.name)) walk(path.join(directory, entry.name));
    } else if (entry.isFile() && entry.name.endsWith(".md")) {
      markdownFiles.push(path.join(directory, entry.name));
    }
  }
}

walk(root);
const failures = [];

for (const file of markdownFiles) {
  const source = fs.readFileSync(file, "utf8");
  const targets = [
    ...Array.from(source.matchAll(/!?\[[^\]]*\]\(([^)]+)\)/g), (match) => match[1]),
    ...Array.from(source.matchAll(/<img\s+[^>]*src=["']([^"']+)["']/gi), (match) => match[1]),
  ];
  for (let target of targets) {
    target = target.trim().replace(/^<|>$/g, "");
    if (!target || target.startsWith("#") || /^[a-z][a-z0-9+.-]*:/i.test(target)) continue;
    target = target.split("#", 1)[0];
    if (target.includes(" ")) target = target.split(/\s+["']/)[0];
    const resolved = path.resolve(path.dirname(file), decodeURIComponent(target));
    if (!fs.existsSync(resolved)) {
      failures.push(`${path.relative(root, file)} -> ${target}`);
    }
  }
}

if (failures.length) {
  console.error("Broken relative Markdown links:\n" + failures.map((value) => `- ${value}`).join("\n"));
  process.exit(1);
}

console.log(`Checked ${markdownFiles.length} Markdown files.`);
