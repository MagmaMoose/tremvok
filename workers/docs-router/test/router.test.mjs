/**
 * The docs router, against a fake `env`: every service binding is a stand-in site Worker that
 * serves a handful of files and records what it was asked for.
 *
 * Run with `node --test workers/docs-router/test/router.test.mjs`, or through pytest
 * (tests/test_docs_router.py), which is how CI runs it. No network, no Wrangler: service
 * bindings to Workers that are not running cannot resolve locally, and the behaviour worth
 * pinning is the router's own.
 */

import assert from "node:assert/strict";
import { beforeEach, describe, mock, test } from "node:test";

import { matchesIfNoneMatch, prefersMarkdown, sha256Source } from "../src/headers.js";
import worker from "../src/index.js";
import { securityTxtExpiry } from "../src/root.js";
import {
  MAX_LOOKUPS_PER_REQUEST,
  describeSites,
  forgetSites,
  listedRepos,
  parseLlmsTxt,
} from "../src/sites.js";

const HOST = "https://docs.magmamoose.com";
const PRIVATE = ["caldrith", "dunmir", "nievah", "noctyr"];

/** A site Worker serving `files` (path -> body, or { status, body, headers }). */
function fakeSite(files = {}) {
  const requests = [];
  return {
    requests,
    async fetch(request) {
      const url = new URL(request.url);
      requests.push({ method: request.method, path: url.pathname, request });
      const file = files[url.pathname];
      if (file === undefined) {
        return new Response("<!doctype html><title>404</title>", {
          status: 404,
          headers: { "content-type": "text/html" },
        });
      }
      if (typeof file === "function") return file(request);
      if (typeof file === "string") {
        return new Response(request.method === "HEAD" ? null : file, {
          headers: { "content-type": "text/plain" },
        });
      }
      return new Response(file.body ?? null, { status: file.status ?? 200, headers: file.headers ?? {} });
    },
  };
}

function llms(title, summary) {
  return `# ${title}\n\n> ${summary}\n\nCanonical documentation for ${title}.\n\n## Docs\n\n- [Home](https://x/): home\n`;
}

/** The live fleet's shape: six public sites, and one private one bound. */
function fleet() {
  return {
    BRIMYR: fakeSite({ "/llms.txt": llms("Brimyr", "Patch coverage for a pull request.") }),
    CHARGATE: fakeSite({ "/llms.txt": llms("Chargate", "A net-new security gate.") }),
    TREMVOK: fakeSite({
      "/llms.txt": llms("Tremvok", "One action for the deploy side, with ‘curly’ quotes."),
      "/": { body: "<html>home</html>", headers: { "content-type": "text/html" } },
      "/setup/": { body: "<html>setup</html>", headers: { "content-type": "text/html", vary: "Accept-Encoding" } },
      "/setup/index.md": { body: "# Setup\n\nMarkdown twin.\n", headers: { "content-type": "text/markdown", etag: '"md1"' } },
      "/setup": { status: 307, headers: { location: "/setup/" } },
      "/llms-full.txt": "# Tremvok\n\nEverything.\n",
    }),
    NIEVAH: fakeSite({ "/llms.txt": llms("Nievah", "A PRIVATE SUMMARY") }),
    PRIVATE_SITES: PRIVATE,
  };
}

function get(env, path, headers = {}, method = "GET") {
  return worker.fetch(new Request(`${HOST}${path}`, { method, headers }), env);
}

const SECURITY_HEADERS = {
  "strict-transport-security": "max-age=63072000; includeSubDomains",
  "x-content-type-options": "nosniff",
  "referrer-policy": "strict-origin-when-cross-origin",
  "x-frame-options": "SAMEORIGIN",
};

function assertHostHeaders(response, label) {
  for (const [name, value] of Object.entries(SECURITY_HEADERS)) {
    assert.equal(response.headers.get(name), value, `${label}: ${name}`);
  }
  assert.match(response.headers.get("permissions-policy") ?? "", /camera=\(\)/, `${label}: permissions-policy`);
}

function jsonLd(html) {
  const match = /<script type="application\/ld\+json">(.*?)<\/script>/s.exec(html);
  assert.ok(match, "the page carries JSON-LD");
  return JSON.parse(match[1]);
}

beforeEach(() => {
  forgetSites();
  mock.restoreAll();
});

// ── The landing page ─────────────────────────────────────────────────────────

describe("GET /", () => {
  test("is a 200 HTML page, not the plain-text 404 it used to be", async () => {
    const res = await get(fleet(), "/");
    assert.equal(res.status, 200);
    assert.equal(res.headers.get("content-type"), "text/html; charset=utf-8");
    const html = await res.text();
    assert.match(html, /^<!doctype html>/);
    assert.match(html, /<html lang="en">/);
    assert.match(html, /<title>Magma Moose documentation<\/title>/);
    assert.match(html, /<link rel="canonical" href="https:\/\/docs\.magmamoose\.com\/">/);
  });

  test("has a meta description of at most 155 characters", async () => {
    const html = await (await get(fleet(), "/")).text();
    const match = /<meta name="description" content="([^"]+)">/.exec(html);
    assert.ok(match);
    assert.ok(match[1].length <= 155, `${match[1].length} characters`);
  });

  test("carries Open Graph and Twitter cards, and the Magma Moose icons", async () => {
    const html = await (await get(fleet(), "/")).text();
    for (const tag of [
      '<meta property="og:type" content="website">',
      '<meta property="og:url" content="https://docs.magmamoose.com/">',
      '<meta property="og:image" content="https://www.magmamoose.com/assets/og/og-magma-moose.png">',
      '<meta property="og:image:width" content="1200">',
      '<meta name="twitter:card" content="summary_large_image">',
      '<link rel="icon" href="https://www.magmamoose.com/assets/favicon.svg" type="image/svg+xml">',
      '<link rel="apple-touch-icon" href="https://www.magmamoose.com/assets/apple-touch-icon.png">',
    ]) {
      assert.ok(html.includes(tag), tag);
    }
    assert.match(html, /<meta property="og:title" content="[^"]+">/);
    assert.match(html, /<meta name="twitter:description" content="[^"]+">/);
  });

  test("lists every public site by the title and summary from its own llms.txt", async () => {
    const html = await (await get(fleet(), "/")).text();
    assert.match(html, /<h2><a href="\/brimyr\/">Brimyr<\/a><\/h2><p>Patch coverage for a pull request\.<\/p>/);
    assert.match(html, /<a href="\/tremvok\/llms\.txt" aria-label="Tremvok llms\.txt">llms\.txt<\/a>/);
    assert.match(html, /<a href="\/tremvok\/llms-full\.txt"/);
    assert.ok(html.includes("‘curly’"), "UTF-8 survives");
  });

  test("describes the sites in JSON-LD: CollectionPage, ItemList, WebSite and the publisher", async () => {
    const graph = jsonLd(await (await get(fleet(), "/")).text())["@graph"];
    const byType = Object.fromEntries(graph.map((node) => [node["@type"], node]));
    assert.deepEqual(byType.Organization, {
      "@type": "Organization",
      "@id": "https://www.magmamoose.com/#organization",
      name: "Magma Moose",
      url: "https://www.magmamoose.com/",
    });
    assert.deepEqual(byType.WebSite.publisher, { "@id": "https://www.magmamoose.com/#organization" });
    assert.deepEqual(byType.CollectionPage.mainEntity, { "@id": byType.ItemList["@id"] });
    assert.deepEqual(byType.CollectionPage.isPartOf, { "@id": byType.WebSite["@id"] });
    assert.equal(byType.ItemList.numberOfItems, 3);
    assert.deepEqual(
      byType.ItemList.itemListElement.map((item) => [item.position, item.name, item.url]),
      [
        [1, "Brimyr", "https://docs.magmamoose.com/brimyr/"],
        [2, "Chargate", "https://docs.magmamoose.com/chargate/"],
        [3, "Tremvok", "https://docs.magmamoose.com/tremvok/"],
      ],
    );
  });

  test("admits its stylesheet by hash, and Web Analytics' beacon host, and nothing inline", async () => {
    const res = await get(fleet(), "/");
    const html = await res.text();
    const csp = res.headers.get("content-security-policy");
    const style = /<style>(.*?)<\/style>/s.exec(html)[1];
    assert.ok(csp.includes(`style-src '${await sha256Source(style)}'`), csp);
    assert.match(csp, /script-src 'self' https:\/\/static\.cloudflareinsights\.com(;|$)/);
    assert.match(csp, /default-src 'none'/);
    assert.match(csp, /frame-ancestors 'self'/);
    assert.doesNotMatch(csp, /script-src[^;]*'unsafe-inline'/);
    assert.equal((html.match(/<script(?![^>]*application\/ld\+json)/g) ?? []).length, 0, "no executable script");
  });

  test("advertises the catalogs and llms.txt in a Link header, and varies on Accept", async () => {
    for (const accept of ["text/html", "text/markdown"]) {
      const res = await get(fleet(), "/", { accept });
      const link = res.headers.get("link");
      assert.match(link, /<\/\.well-known\/api-catalog>; rel="api-catalog"/, accept);
      assert.match(link, /<\/\.well-known\/ai-catalog\.json>; rel="ai-catalog"; type="application\/ai-catalog\+json"/, accept);
      assert.match(link, /<\/llms\.txt>; rel="describedby"; type="text\/plain"/, accept);
      assert.equal(res.headers.get("vary"), "Accept", accept);
    }
  });

  test("answers Accept: text/markdown with the same list, as markdown", async () => {
    const res = await get(fleet(), "/", { accept: "text/markdown" });
    assert.equal(res.headers.get("content-type"), "text/markdown; charset=utf-8");
    const body = await res.text();
    assert.match(body, /^# Magma Moose documentation\n/);
    assert.match(body, /^- \[Brimyr\]\(https:\/\/docs\.magmamoose\.com\/brimyr\/\)/m);
    assert.equal(body, await (await get(fleet(), "/llms.txt")).text());
  });

  test("a browser's Accept gets HTML", async () => {
    const res = await get(fleet(), "/", { accept: "text/html,application/xhtml+xml,*/*;q=0.8" });
    assert.equal(res.headers.get("content-type"), "text/html; charset=utf-8");
  });

  test("still lists a site whose llms.txt is missing, broken or hangs, by its repository name", async () => {
    const env = {
      DIATREME: fakeSite({}),
      DRAVENTIS: fakeSite({ "/llms.txt": { body: "<!doctype html><p>oops</p>", headers: { "content-type": "text/html" } } }),
      PONVARA: { fetch: async () => { throw new Error("binding exploded"); } },
    };
    const res = await get(env, "/");
    assert.equal(res.status, 200);
    const html = await res.text();
    for (const repo of ["diatreme", "draventis", "ponvara"]) {
      assert.match(html, new RegExp(`<h2><a href="/${repo}/">${repo}</a></h2><p class="alt">`), repo);
    }
    assert.doesNotMatch(html, /oops/);
  });

  test("escapes what a site's llms.txt says about itself", async () => {
    const env = {
      EVIL: fakeSite({ "/llms.txt": llms('<img src=x onerror=alert(1)> "x"', "</script><script>alert(2)</script>") }),
    };
    const html = await (await get(env, "/")).text();
    assert.doesNotMatch(html, /<img src=x/);
    assert.doesNotMatch(html, /<\/script><script>alert/);
    assert.match(html, /&lt;img src=x onerror=alert\(1\)&gt; &quot;x&quot;/);
    const item = jsonLd(html)["@graph"].find((node) => node["@type"] === "ItemList").itemListElement[0];
    assert.equal(item.description, "</script><script>alert(2)</script>");
  });

  test("with no sites bound, says so instead of rendering an empty list", async () => {
    const html = await (await get({}, "/")).text();
    assert.match(html, /No documentation sites are published yet\./);
  });

  test("answers If-None-Match with a 304", async () => {
    const etag = (await get(fleet(), "/")).headers.get("etag");
    const res = await get(fleet(), "/", { "if-none-match": `W/${etag}` });
    assert.equal(res.status, 304);
    assert.equal(await res.text(), "");
  });

  test("refuses anything but GET and HEAD", async () => {
    const res = await get(fleet(), "/", {}, "POST");
    assert.equal(res.status, 405);
    assert.equal(res.headers.get("allow"), "GET, HEAD");
    assert.equal((await get(fleet(), "/", {}, "HEAD")).status, 200);
  });
});

// ── Private sites ────────────────────────────────────────────────────────────

describe("a private site", () => {
  test("is routed but never listed, and its llms.txt is never read", async () => {
    const env = fleet();
    const surfaces = ["/", "/llms.txt", "/sitemap.xml", "/nope/"];
    for (const path of surfaces) {
      const body = await (await get(env, path)).text();
      assert.doesNotMatch(body, /nievah|PRIVATE SUMMARY/i, path);
    }
    assert.deepEqual(env.NIEVAH.requests, [], "the router read a private site's content");
    // Routing is unchanged: Access gates the path at the edge, before this Worker.
    assert.equal((await get(env, "/nievah/llms.txt")).status, 200);
  });

  test("an unbound one appears nowhere, even though PRIVATE_SITES names it", async () => {
    const env = fleet();
    for (const path of ["/", "/llms.txt", "/sitemap.xml", "/robots.txt", "/nope/", "/.well-known/ai-catalog.json"]) {
      const body = await (await get(env, path)).text();
      for (const name of ["caldrith", "dunmir", "noctyr"]) {
        assert.ok(!body.toLowerCase().includes(name), `${path} names ${name}`);
      }
    }
  });

  test("PRIVATE_SITES may be a string as well as a JSON array", () => {
    assert.deepEqual(listedRepos({ ...fleet(), PRIVATE_SITES: "nievah, other" }), ["brimyr", "chargate", "tremvok"]);
    assert.deepEqual(listedRepos({ ...fleet(), PRIVATE_SITES: undefined }), ["brimyr", "chargate", "nievah", "tremvok"]);
  });
});

// ── The per-isolate cache and its bounds ─────────────────────────────────────

describe("reading llms.txt", () => {
  test("is cached per isolate for five minutes", async () => {
    let now = 1_000_000;
    mock.method(Date, "now", () => now);
    const env = fleet();
    await get(env, "/");
    await get(env, "/llms.txt");
    assert.equal(env.BRIMYR.requests.length, 1, "a second request inside the TTL read it again");
    now += 5 * 60 * 1000 + 1;
    await get(env, "/");
    assert.equal(env.BRIMYR.requests.length, 2, "an expired entry was not refreshed");
  });

  test("a failure is retried after thirty seconds, and a good description outlives it", async () => {
    let now = 1_000_000;
    mock.method(Date, "now", () => now);
    let healthy = true;
    const env = {
      BRIMYR: fakeSite({
        "/llms.txt": () =>
          healthy
            ? new Response(llms("Brimyr", "Good summary."))
            : new Response("down", { status: 503 }),
      }),
    };
    await get(env, "/");
    healthy = false;
    now += 5 * 60 * 1000 + 1;
    const stale = await (await get(env, "/")).text();
    assert.match(stale, /Good summary\./, "a failed refresh blanked a description that was good");
    now += 29 * 1000;
    await get(env, "/");
    assert.equal(env.BRIMYR.requests.length, 2, "retried inside thirty seconds");
    now += 2 * 1000;
    await get(env, "/");
    assert.equal(env.BRIMYR.requests.length, 3, "not retried after thirty seconds");
  });

  test(`reads at most ${MAX_LOOKUPS_PER_REQUEST} sites in one request, and still lists the rest`, async () => {
    const env = {};
    for (let i = 0; i < 40; i += 1) {
      env[`SITE_${String(i).padStart(2, "0")}`] = fakeSite({ "/llms.txt": llms(`Site ${i}`, "Summary.") });
    }
    const html = await (await get(env, "/")).text();
    const reads = Object.values(env).reduce((sum, site) => sum + site.requests.length, 0);
    assert.equal(reads, MAX_LOOKUPS_PER_REQUEST);
    assert.equal((html.match(/<li class="site">/g) ?? []).length, 40);
  });

  test("a site that hangs costs the root its timeout, not its answer", async () => {
    const hung = {
      fetch: (request) =>
        new Promise((_, reject) => {
          request.signal.addEventListener("abort", () => reject(request.signal.reason));
        }),
    };
    const [site] = await describeSites({ HUNG: hung }, ["hung"], HOST, { timeoutMs: 20 });
    assert.deepEqual(site, { repo: "hung", title: "hung", summary: null, described: false });
  });

  test("parses the H1 and the first blockquote line, and nothing that is not an llms.txt", () => {
    assert.deepEqual(parseLlmsTxt("# Brimyr\n\n> Patch coverage.\n\n## Docs\n"), { title: "Brimyr", summary: "Patch coverage." });
    assert.deepEqual(parseLlmsTxt("﻿# T\r\n\r\n>No space\r\n"), { title: "T", summary: "No space" });
    assert.deepEqual(parseLlmsTxt("# T\n\nProse first.\n\n> Later.\n"), { title: "T", summary: "Later." });
    assert.deepEqual(parseLlmsTxt("# T\n\n## Docs\n\n> Not the summary.\n"), { title: "T", summary: null });
    assert.deepEqual(parseLlmsTxt("<!doctype html>\n# Not a title"), { title: null, summary: null });
    assert.deepEqual(parseLlmsTxt("#NoSpace"), { title: null, summary: null });
    assert.deepEqual(parseLlmsTxt(""), { title: null, summary: null });
    const long = parseLlmsTxt(`# ${"t".repeat(200)}\n\n> ${"s".repeat(500)}`);
    assert.ok(long.title.length <= 80 && long.title.endsWith("…"));
    assert.ok(long.summary.length <= 300 && long.summary.endsWith("…"));
  });

  test("reads only the head of a large llms.txt", async () => {
    let pulled = 0;
    const endless = new ReadableStream({
      pull(controller) {
        pulled += 1;
        controller.enqueue(new TextEncoder().encode(pulled === 1 ? "# Big\n\n> Summary.\n" : "x".repeat(4096)));
      },
    });
    const env = { BIG: { fetch: async () => new Response(endless) } };
    const [site] = await describeSites(env, ["big"], HOST);
    assert.deepEqual(site, { repo: "big", title: "Big", summary: "Summary.", described: true });
    assert.ok(pulled < 10, `read ${pulled} chunks of an endless file`);
  });
});

// ── The other root documents ─────────────────────────────────────────────────

describe("root documents", () => {
  test("robots.txt allows everything, signals content use, and names the sitemap and catalog", async () => {
    const res = await get(fleet(), "/robots.txt");
    assert.equal(res.status, 200);
    assert.equal(res.headers.get("content-type"), "text/plain; charset=utf-8");
    const body = await res.text();
    assert.match(body, /^User-agent: \*$/m);
    assert.match(body, /^Content-Signal: search=yes, ai-input=yes, ai-train=yes$/m);
    assert.match(body, /^Allow: \/$/m);
    assert.match(body, /^Disallow: \/cdn-cgi\/$/m);
    assert.match(body, /^Sitemap: https:\/\/docs\.magmamoose\.com\/sitemap\.xml$/m);
    assert.match(body, /^Agentmap: https:\/\/docs\.magmamoose\.com\/\.well-known\/ai-catalog\.json$/m);
    assert.match(body, /^#.*\/llms\.txt/m);
    assert.match(body, /^#.*https:\/\/mcp\.magmamoose\.com\//m);
  });

  test("sitemap.xml is a sitemap index of every public site, read from nothing but the bindings", async () => {
    const env = fleet();
    const res = await get(env, "/sitemap.xml");
    assert.equal(res.headers.get("content-type"), "application/xml; charset=utf-8");
    const body = await res.text();
    assert.match(body, /^<\?xml version="1\.0" encoding="UTF-8"\?>\n<sitemapindex xmlns="http:\/\/www\.sitemaps\.org\/schemas\/sitemap\/0\.9">/);
    assert.deepEqual(
      [...body.matchAll(/<loc>([^<]+)<\/loc>/g)].map((m) => m[1]),
      ["brimyr", "chargate", "tremvok"].map((repo) => `https://docs.magmamoose.com/${repo}/sitemap.xml`),
    );
    const reads = [env.BRIMYR, env.CHARGATE, env.TREMVOK].reduce((sum, site) => sum + site.requests.length, 0);
    assert.equal(reads, 0, "the sitemap index fetched something");
  });

  test("llms.txt is an llmstxt.org index linking each site, its llms.txt and its llms-full.txt", async () => {
    const res = await get(fleet(), "/llms.txt");
    assert.equal(res.headers.get("content-type"), "text/plain; charset=utf-8");
    const body = await res.text();
    const lines = body.split("\n");
    assert.equal(lines[0], "# Magma Moose documentation");
    assert.match(lines[2], /^> \S/);
    assert.match(body, /^The same documentation is searchable over MCP at https:\/\/mcp\.magmamoose\.com\/: /m);
    const site = "https://docs.magmamoose.com/tremvok/";
    assert.ok(
      lines.includes(
        `- [Tremvok](${site}): One action for the deploy side, with ‘curly’ quotes. ([llms.txt](${site}llms.txt), [llms-full.txt](${site}llms-full.txt))`,
      ),
      body,
    );
  });

  test("llms.txt still links a site it could not describe", async () => {
    const body = await (await get({ DIATREME: fakeSite({}) }, "/llms.txt")).text();
    const site = "https://docs.magmamoose.com/diatreme/";
    assert.ok(
      body.split("\n").includes(`- [diatreme](${site}): [llms.txt](${site}llms.txt), [llms-full.txt](${site}llms-full.txt)`),
      body,
    );
  });

  test("security.txt is RFC 9116, with an Expires that is always in the future", async () => {
    const res = await get(fleet(), "/.well-known/security.txt");
    assert.equal(res.headers.get("content-type"), "text/plain; charset=utf-8");
    const body = await res.text();
    assert.match(body, /^Contact: mailto:hello@magmamoose\.com$/m);
    assert.match(body, /^Preferred-Languages: en$/m);
    assert.match(body, /^Canonical: https:\/\/docs\.magmamoose\.com\/\.well-known\/security\.txt$/m);
    const expires = new Date(/^Expires: (\S+)$/m.exec(body)[1]);
    assert.ok(expires > new Date(), "Expires is in the past");
  });

  test("Expires is the first of the month six months on, across a year boundary", () => {
    assert.equal(securityTxtExpiry(new Date("2026-09-23T10:00:00Z")), "2027-03-01T00:00:00Z");
    assert.equal(securityTxtExpiry(new Date("2026-12-31T23:59:59Z")), "2027-06-01T00:00:00Z");
    assert.equal(securityTxtExpiry(new Date("2026-06-01T00:00:00Z")), "2026-12-01T00:00:00Z");
  });

  test("the conventional icon paths and the legacy security.txt path redirect", async () => {
    const cases = {
      "/favicon.ico": [301, "https://www.magmamoose.com/assets/favicon.ico"],
      "/apple-touch-icon.png": [301, "https://www.magmamoose.com/assets/apple-touch-icon.png"],
      "/security.txt": [301, "/.well-known/security.txt"],
      "/.well-known/mcp/server-card.json": [302, "https://mcp.magmamoose.com/server-card"],
    };
    for (const [path, [status, location]] of Object.entries(cases)) {
      const res = await get(fleet(), path);
      assert.equal(res.status, status, path);
      assert.equal(res.headers.get("location"), location, path);
    }
  });

  test("an unknown path is still a 404: a small HTML page that links home and echoes nothing", async () => {
    const res = await get(fleet(), "/%3Cscript%3Ealert(1)%3C%2Fscript%3E/");
    assert.equal(res.status, 404);
    assert.equal(res.headers.get("content-type"), "text/html; charset=utf-8");
    const html = await res.text();
    assert.match(html, /<meta name="robots" content="noindex">/);
    assert.match(html, /<a href="\/">All Magma Moose documentation<\/a>/);
    assert.match(html, /<a href="\/tremvok\/">tremvok<\/a>/);
    assert.doesNotMatch(html, /alert/);
  });

  test("root documents answer If-None-Match with a 304", async () => {
    for (const path of ["/robots.txt", "/sitemap.xml", "/llms.txt", "/.well-known/security.txt"]) {
      const etag = (await get(fleet(), path)).headers.get("etag");
      assert.match(etag, /^"[0-9a-f]{32}"$/, path);
      assert.equal((await get(fleet(), path, { "if-none-match": etag })).status, 304, path);
    }
  });
});

// ── Discovery ────────────────────────────────────────────────────────────────

describe("discovery", () => {
  test("the AI Catalog lists the MCP server's card, with CORS, caching and an ETag", async () => {
    const res = await get(fleet(), "/.well-known/ai-catalog.json");
    assert.equal(res.status, 200);
    assert.equal(res.headers.get("content-type"), "application/ai-catalog+json");
    assert.equal(res.headers.get("access-control-allow-origin"), "*");
    assert.match(res.headers.get("access-control-expose-headers"), /ETag/);
    assert.equal(res.headers.get("cache-control"), "public, max-age=3600");
    assert.match(res.headers.get("etag"), /^"[0-9a-f]{32}"$/);
    const catalog = await res.json();
    assert.equal(catalog.specVersion, "1.0");
    assert.equal(catalog.host.displayName, "Magma Moose");
    assert.equal(catalog.entries.length, 1);
    const [entry] = catalog.entries;
    assert.equal(entry.identifier, "urn:air:magmamoose.com:mcp:docs");
    assert.equal(entry.type, "application/mcp-server-card+json");
    assert.equal(entry.url, "https://mcp.magmamoose.com/server-card");
    assert.ok(entry.displayName);
    assert.ok(entry.description.length >= 1 && entry.description.length <= 100);
    assert.ok(entry.representativeQueries.length >= 2 && entry.representativeQueries.length <= 5);
  });

  test("the API catalog is an RFC 9727 linkset that names itself, HEAD included", async () => {
    for (const method of ["GET", "HEAD"]) {
      const res = await get(fleet(), "/.well-known/api-catalog", {}, method);
      assert.equal(res.status, 200, method);
      assert.equal(
        res.headers.get("content-type"),
        'application/linkset+json; profile="https://www.rfc-editor.org/info/rfc9727"',
      );
      assert.equal(res.headers.get("link"), '</.well-known/api-catalog>; rel="api-catalog"', method);
      assert.equal(res.headers.get("cache-control"), "public, max-age=3600", method);
    }
    const { linkset } = await (await get(fleet(), "/.well-known/api-catalog")).json();
    assert.equal(linkset[0].anchor, "https://docs.magmamoose.com/.well-known/api-catalog");
    assert.deepEqual(linkset[0].item.map((link) => link.href), ["https://mcp.magmamoose.com/"]);
    const api = linkset.find((link) => link.anchor === "https://mcp.magmamoose.com/");
    assert.equal(api["service-desc"][0].href, "https://mcp.magmamoose.com/server-card");
    assert.equal(api["service-desc"][0].type, "application/mcp-server-card+json");
    assert.equal(api["service-doc"][0].href, "https://docs.magmamoose.com/");
  });

  test("If-None-Match with the current ETag is a 304 with no body", async () => {
    const etag = (await get(fleet(), "/.well-known/ai-catalog.json")).headers.get("etag");
    const res = await get(fleet(), "/.well-known/ai-catalog.json", { "if-none-match": `W/${etag}, "other"` });
    assert.equal(res.status, 304);
    assert.equal(res.headers.get("etag"), etag);
    assert.equal(await res.text(), "");
  });

  test("If-None-Match matching", () => {
    assert.equal(matchesIfNoneMatch(null, '"a"'), false);
    assert.equal(matchesIfNoneMatch("*", '"a"'), true);
    assert.equal(matchesIfNoneMatch('"b", W/"a"', '"a"'), true);
    assert.equal(matchesIfNoneMatch('"b"', '"a"'), false);
  });

  test("discovery paths answer GET and HEAD only", async () => {
    assert.equal((await get(fleet(), "/.well-known/ai-catalog.json", {}, "POST")).status, 405);
  });
});

// ── Dispatch to the sites ────────────────────────────────────────────────────

describe("a site path", () => {
  test("reaches the site Worker with the prefix stripped and the trailing slash kept", async () => {
    const env = fleet();
    const res = await get(env, "/tremvok/setup/?x=1");
    assert.equal(res.status, 200);
    assert.equal(await res.text(), "<html>setup</html>");
    assert.equal(env.TREMVOK.requests.at(-1).path, "/setup/");
    assert.equal(new URL(env.TREMVOK.requests.at(-1).request.url).search, "?x=1");
  });

  test("a site root without its slash is a 301 to the slash, query kept", async () => {
    const res = await get(fleet(), "/tremvok?x=1");
    assert.equal(res.status, 301);
    assert.equal(res.headers.get("location"), "/tremvok/?x=1");
  });

  test("a non-canonical spelling of the site segment is a 301, and never reaches the site", async () => {
    const env = fleet();
    const cases = {
      "/Tremvok/setup/": "/tremvok/setup/",
      "/TREMVOK": "/tremvok/",
      "/tremvok//setup/": "/tremvok/setup/",
      "/NIEVAH/secret/": "/nievah/secret/",
    };
    for (const [path, location] of Object.entries(cases)) {
      const res = await get(env, path);
      assert.equal(res.status, 301, path);
      assert.equal(res.headers.get("location"), location, path);
    }
    assert.deepEqual(env.TREMVOK.requests, []);
    assert.deepEqual(env.NIEVAH.requests, []);
  });

  test("the site Worker's own redirects get the /<repo> prefix back", async () => {
    const res = await get(fleet(), "/tremvok/setup");
    assert.equal(res.status, 307);
    assert.equal(res.headers.get("location"), "/tremvok/setup/");
  });

  test("only a path-absolute Location is rewritten", async () => {
    const env = {
      SITE: fakeSite({
        "/a": { status: 302, headers: { location: "//elsewhere.example/x" } },
        "/b": { status: 302, headers: { location: "https://elsewhere.example/x" } },
        "/c": { status: 302, headers: { location: "relative/" } },
      }),
    };
    assert.equal((await get(env, "/site/a")).headers.get("location"), "//elsewhere.example/x");
    assert.equal((await get(env, "/site/b")).headers.get("location"), "https://elsewhere.example/x");
    assert.equal((await get(env, "/site/c")).headers.get("location"), "relative/");
  });

  test("every site response carries the host's security headers, and no CSP", async () => {
    const env = fleet();
    for (const path of ["/tremvok/", "/tremvok/setup", "/tremvok/missing/", "/tremvok/llms.txt"]) {
      const res = await get(env, path);
      assertHostHeaders(res, path);
      assert.equal(res.headers.get("content-security-policy"), null, path);
    }
  });

  test("the site's own headers survive", async () => {
    const env = {
      SITE: fakeSite({
        "/x.css": { body: "a{}", headers: { "content-type": "text/css", etag: '"abc"', "cache-control": "public, max-age=0, must-revalidate" } },
      }),
    };
    const res = await get(env, "/site/x.css");
    assert.equal(res.headers.get("etag"), '"abc"');
    assert.equal(res.headers.get("cache-control"), "public, max-age=0, must-revalidate");
    assert.equal(res.headers.get("content-type"), "text/css");
  });

  test(".txt is served as UTF-8 plain text and .md as UTF-8 markdown, on success only", async () => {
    const env = fleet();
    assert.equal((await get(env, "/tremvok/llms.txt")).headers.get("content-type"), "text/plain; charset=utf-8");
    assert.equal((await get(env, "/tremvok/setup/index.md")).headers.get("content-type"), "text/markdown; charset=utf-8");
    const missing = await get(env, "/tremvok/nothing.txt");
    assert.equal(missing.status, 404);
    assert.equal(missing.headers.get("content-type"), "text/html");
  });

  test("a page's index.md names the page as canonical", async () => {
    const res = await get(fleet(), "/tremvok/setup/index.md");
    assert.equal(res.headers.get("link"), '<https://docs.magmamoose.com/tremvok/setup/>; rel="canonical"');
  });

  test("an unknown repository is a 404, whatever the method", async () => {
    assert.equal((await get(fleet(), "/nope/")).status, 404);
    assert.equal((await get(fleet(), "/nope/", {}, "POST")).status, 404);
    assert.equal((await get(fleet(), "/private-sites/")).status, 404, "a var is not a site");
    assert.equal((await get(fleet(), "/constructor/")).status, 404, "Object.prototype is not a site");
  });

  test("a site Worker that throws is a 502 with the host's headers, not Cloudflare's error page", async () => {
    const original = console.error;
    console.error = () => {};
    try {
      const env = { SITE: { fetch: async () => { throw new Error("site exploded"); } } };
      const res = await get(env, "/site/page/");
      assert.equal(res.status, 502);
      assert.equal(res.headers.get("cache-control"), "no-store");
      assertHostHeaders(res, "502");
    } finally {
      console.error = original;
    }
  });

  test("other methods pass through untouched", async () => {
    const env = { SITE: fakeSite({ "/form": (request) => new Response(`got ${request.method}`) }) };
    const res = await worker.fetch(new Request(`${HOST}/site/form`, { method: "POST", body: "x" }), env);
    assert.equal(await res.text(), "got POST");
  });
});

// ── Markdown negotiation ─────────────────────────────────────────────────────

describe("Accept: text/markdown on a page", () => {
  test("serves the page's index.md twin as markdown, canonical to the page", async () => {
    const env = fleet();
    const res = await get(env, "/tremvok/setup/", { accept: "text/markdown, text/html;q=0.9" });
    assert.equal(res.status, 200);
    assert.equal(res.headers.get("content-type"), "text/markdown; charset=utf-8");
    assert.equal(res.headers.get("vary"), "Accept");
    assert.equal(res.headers.get("link"), '<https://docs.magmamoose.com/tremvok/setup/>; rel="canonical"');
    assert.equal(await res.text(), "# Setup\n\nMarkdown twin.\n");
    assertHostHeaders(res, "markdown twin");
    assert.deepEqual(env.TREMVOK.requests.map((r) => r.path), ["/setup/index.md"]);
  });

  test("falls back to the HTML page when the site has no twin", async () => {
    const env = fleet();
    const res = await get(env, "/tremvok/", { accept: "text/markdown" });
    assert.equal(res.headers.get("content-type"), "text/html");
    assert.equal(await res.text(), "<html>home</html>");
    assert.equal(res.headers.get("vary"), "Accept");
    assert.deepEqual(env.TREMVOK.requests.map((r) => r.path), ["/index.md", "/"]);
  });

  test("falls back to the HTML page when reading the twin throws", async () => {
    const env = {
      SITE: fakeSite({
        "/page/index.md": () => {
          throw new Error("twin exploded");
        },
        "/page/": { body: "<html>page</html>", headers: { "content-type": "text/html" } },
      }),
    };
    const res = await get(env, "/site/page/", { accept: "text/markdown" });
    assert.equal(res.status, 200);
    assert.equal(await res.text(), "<html>page</html>");
  });

  test("HEAD is answered from the twin too", async () => {
    const res = await get(fleet(), "/tremvok/setup/", { accept: "text/markdown" }, "HEAD");
    assert.equal(res.status, 200);
    assert.equal(res.headers.get("content-type"), "text/markdown; charset=utf-8");
  });

  test("a 304 from the twin stays a markdown 304", async () => {
    const env = {
      SITE: fakeSite({
        "/page/index.md": (request) =>
          request.headers.get("if-none-match") === '"md1"'
            ? new Response(null, { status: 304, headers: { etag: '"md1"' } })
            : new Response("# Page\n"),
      }),
    };
    const res = await get(env, "/site/page/", { accept: "text/markdown", "if-none-match": '"md1"' });
    assert.equal(res.status, 304);
    assert.equal(res.headers.get("vary"), "Accept");
  });

  test("only when markdown is the FIRST media range, and only on a page path", async () => {
    const env = fleet();
    const html = await get(env, "/tremvok/setup/", { accept: "text/html, text/markdown" });
    assert.equal(html.headers.get("content-type"), "text/html");
    const txt = await get(env, "/tremvok/llms.txt", { accept: "text/markdown" });
    assert.equal(txt.headers.get("content-type"), "text/plain; charset=utf-8");
    assert.ok(!env.TREMVOK.requests.some((r) => r.path.endsWith("index.md")), "fetched a twin it should not have");
  });

  test("the HTML for a page path varies on Accept, keeping the site's own Vary", async () => {
    const res = await get(fleet(), "/tremvok/setup/");
    assert.equal(res.headers.get("vary"), "Accept-Encoding, Accept");
    const file = await get(fleet(), "/tremvok/llms.txt");
    assert.equal(file.headers.get("vary"), null);
  });

  test("prefersMarkdown reads the first media range and its q", () => {
    assert.equal(prefersMarkdown("text/markdown"), true);
    assert.equal(prefersMarkdown("Text/Markdown; charset=utf-8, text/html"), true);
    assert.equal(prefersMarkdown("text/markdown;q=0, text/html"), false);
    assert.equal(prefersMarkdown("text/html, text/markdown"), false);
    assert.equal(prefersMarkdown("*/*"), false);
    assert.equal(prefersMarkdown(null), false);
  });
});

// ── One header policy for the host ───────────────────────────────────────────

describe("every response", () => {
  test("carries the host's security headers, whoever produced it", async () => {
    const env = fleet();
    const paths = [
      "/",
      "/llms.txt",
      "/robots.txt",
      "/sitemap.xml",
      "/.well-known/security.txt",
      "/.well-known/ai-catalog.json",
      "/.well-known/api-catalog",
      "/.well-known/mcp/server-card.json",
      "/favicon.ico",
      "/nope/",
      "/tremvok",
      "/Tremvok/",
      "/tremvok/",
      "/tremvok/setup",
      "/tremvok/missing/",
    ];
    for (const path of paths) assertHostHeaders(await get(env, path), path);
    assertHostHeaders(await get(env, "/", {}, "DELETE"), "405");
  });

  test("the router's own documents carry a CSP; HTML ones the page policy", async () => {
    const env = fleet();
    for (const path of ["/", "/nope/"]) {
      assert.match((await get(env, path)).headers.get("content-security-policy"), /style-src 'sha256-/, path);
    }
    for (const path of ["/robots.txt", "/llms.txt", "/sitemap.xml", "/.well-known/ai-catalog.json", "/favicon.ico"]) {
      assert.match((await get(env, path)).headers.get("content-security-policy"), /^default-src 'none'/, path);
    }
  });
});
