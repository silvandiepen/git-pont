import { mkdir, readFile, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const configPath = path.join(__dirname, "girk.json");
const config = JSON.parse(await readFile(configPath, "utf8"));
const contentDir = path.resolve(__dirname, config.contentDir);
const outputDir = path.resolve(__dirname, config.outputDir);

await rm(outputDir, { recursive: true, force: true });
await mkdir(outputDir, { recursive: true });

const pages = [];
for (const filename of config.navigation) {
  const source = path.join(contentDir, filename);
  const markdown = await readFile(source, "utf8");
  const title = firstHeading(markdown) ?? filename.replace(/\.md$/, "");
  const htmlName = filename.replace(/\.md$/, ".html");
  const html = renderPage({
    siteTitle: config.title,
    title,
    body: markdownToHtml(markdown),
    navigation: config.navigation,
    current: filename
  });
  await writeFile(path.join(outputDir, htmlName), html);
  pages.push({ title, href: htmlName });
}

await writeFile(
  path.join(outputDir, "sitemap.json"),
  JSON.stringify({ pages }, null, 2)
);

console.log(`Built ${pages.length} docs pages in ${path.relative(process.cwd(), outputDir)}`);

function firstHeading(markdown) {
  const match = markdown.match(/^#\s+(.+)$/m);
  return match?.[1]?.trim();
}

function renderPage({ siteTitle, title, body, navigation, current }) {
  const nav = navigation.map((filename) => {
    const href = filename.replace(/\.md$/, ".html");
    const label = titleCase(filename.replace(/\.md$/, "").replaceAll("-", " "));
    const aria = filename === current ? ` aria-current="page"` : "";
    return `<a href="${escapeHtml(href)}"${aria}>${escapeHtml(label)}</a>`;
  }).join("\n");

  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${escapeHtml(title)} | ${escapeHtml(siteTitle)}</title>
  <style>
    :root {
      color-scheme: light dark;
      --bg: #f8f9fb;
      --fg: #1b1f24;
      --muted: #667085;
      --line: #d9dee7;
      --panel: #ffffff;
      --accent: #126a8a;
      --code: #eef3f7;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --bg: #101418;
        --fg: #eef2f6;
        --muted: #a7b0bd;
        --line: #303842;
        --panel: #171d23;
        --accent: #62c1df;
        --code: #222a32;
      }
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      font: 16px/1.6 system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      background: var(--bg);
      color: var(--fg);
    }
    .layout {
      display: grid;
      grid-template-columns: 280px minmax(0, 1fr);
      min-height: 100vh;
    }
    nav {
      border-right: 1px solid var(--line);
      background: var(--panel);
      padding: 24px;
      position: sticky;
      top: 0;
      height: 100vh;
      overflow: auto;
    }
    nav strong {
      display: block;
      margin-bottom: 16px;
      font-size: 18px;
    }
    nav a {
      display: block;
      color: var(--muted);
      text-decoration: none;
      padding: 6px 0;
    }
    nav a[aria-current="page"], nav a:hover { color: var(--accent); }
    main {
      max-width: 920px;
      padding: 48px 32px 72px;
    }
    h1, h2, h3 { line-height: 1.2; }
    h1 { font-size: 42px; margin: 0 0 24px; }
    h2 { margin-top: 40px; padding-top: 8px; border-top: 1px solid var(--line); }
    a { color: var(--accent); }
    pre, code {
      font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
      background: var(--code);
      border-radius: 6px;
    }
    code { padding: 0.12em 0.32em; }
    pre {
      overflow: auto;
      padding: 16px;
    }
    pre code { padding: 0; background: transparent; }
    blockquote {
      margin-left: 0;
      padding-left: 16px;
      border-left: 4px solid var(--line);
      color: var(--muted);
    }
    table { border-collapse: collapse; width: 100%; }
    th, td { border: 1px solid var(--line); padding: 8px 10px; }
    @media (max-width: 800px) {
      .layout { display: block; }
      nav {
        position: static;
        height: auto;
        border-right: 0;
        border-bottom: 1px solid var(--line);
      }
      main { padding: 32px 20px 56px; }
      h1 { font-size: 34px; }
    }
  </style>
</head>
<body>
  <div class="layout">
    <nav>
      <strong>${escapeHtml(siteTitle)}</strong>
      ${nav}
    </nav>
    <main>${body}</main>
  </div>
</body>
</html>
`;
}

function markdownToHtml(markdown) {
  const lines = markdown.replace(/\r\n/g, "\n").split("\n");
  const html = [];
  let paragraph = [];
  let list = null;
  let fence = null;
  let code = [];

  for (const line of lines) {
    const fenceMatch = line.match(/^```(.*)$/);
    if (fenceMatch) {
      if (fence) {
        html.push(`<pre><code>${escapeHtml(code.join("\n"))}</code></pre>`);
        fence = null;
        code = [];
      } else {
        flushParagraph();
        closeList();
        fence = fenceMatch[1] || "plain";
      }
      continue;
    }
    if (fence) {
      code.push(line);
      continue;
    }

    if (/^\s*$/.test(line)) {
      flushParagraph();
      closeList();
      continue;
    }

    const heading = line.match(/^(#{1,4})\s+(.+)$/);
    if (heading) {
      flushParagraph();
      closeList();
      const level = heading[1].length;
      html.push(`<h${level}>${inline(heading[2])}</h${level}>`);
      continue;
    }

    const bullet = line.match(/^\s*-\s+(.+)$/);
    if (bullet) {
      flushParagraph();
      if (list !== "ul") {
        closeList();
        html.push("<ul>");
        list = "ul";
      }
      html.push(`<li>${inline(bullet[1])}</li>`);
      continue;
    }

    const ordered = line.match(/^\s*\d+\.\s+(.+)$/);
    if (ordered) {
      flushParagraph();
      if (list !== "ol") {
        closeList();
        html.push("<ol>");
        list = "ol";
      }
      html.push(`<li>${inline(ordered[1])}</li>`);
      continue;
    }

    paragraph.push(line.trim());
  }

  flushParagraph();
  closeList();
  if (fence) {
    html.push(`<pre><code>${escapeHtml(code.join("\n"))}</code></pre>`);
  }

  return html.join("\n");

  function flushParagraph() {
    if (!paragraph.length) return;
    html.push(`<p>${inline(paragraph.join(" "))}</p>`);
    paragraph = [];
  }

  function closeList() {
    if (!list) return;
    html.push(list === "ul" ? "</ul>" : "</ol>");
    list = null;
  }
}

function inline(value) {
  return escapeHtml(value)
    .replace(/`([^`]+)`/g, "<code>$1</code>")
    .replace(/\[([^\]]+)\]\(([^)]+)\)/g, (_, label, href) => {
      const htmlHref = href.endsWith(".md") ? href.replace(/\.md$/, ".html") : href;
      return `<a href="${escapeHtml(htmlHref)}">${label}</a>`;
    })
    .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>");
}

function escapeHtml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function titleCase(value) {
  return value.replace(/\b\w/g, (char) => char.toUpperCase());
}
