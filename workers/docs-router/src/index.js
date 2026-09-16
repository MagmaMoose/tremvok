/**
 * docs.magmamoose.com — the router.
 *
 * One hostname, N documentation sites. Cloudflare will not let two Workers share a hostname
 * by path, so this Worker owns `docs.magmamoose.com/*` and dispatches `/<repo>/…` to that
 * repository's own docs Worker.
 *
 * IT DISPATCHES OVER A SERVICE BINDING, NOT AN HTTP PROXY, and per ADR-0005 that is the
 * load-bearing detail rather than an implementation preference:
 *
 *   - An HTTP proxy needs a public origin hostname for every site. `workers_dev = false`
 *     exists across the org precisely to prevent those from existing.
 *   - Proxying an Access-gated origin requires this router to hold a service token. At that
 *     point Access is no longer gating the *user* — the router is — and `require-access` is
 *     checking a hostname nobody visits.
 *
 * With a service binding there is no public origin to gate and no token to hold. The gate
 * sits once, path-scoped, on this hostname.
 *
 * `env.<BINDING>.fetch()` is an in-process dispatch to another Worker on Cloudflare's
 * network. It never leaves as an HTTP request, so there is nothing on the wire to
 * authenticate and no second hostname to protect.
 */

/**
 * The repository a path segment names, mapped to its binding.
 *
 * Derived from `env` rather than kept as a second list: a table here and a `[[services]]`
 * block in wrangler.toml would be two places to add a repository, and the failure mode of
 * missing one is a 404 that looks like a broken deploy. `wrangler.toml` is the only list.
 */
function bindingNameFor(segment) {
  // `noctyr` -> NOCTYR, `oblivious-tls` -> OBLIVIOUS_TLS. Upper snake, because a binding
  // name is a JavaScript identifier on `env` and a hyphen is not one.
  return segment.toUpperCase().replace(/-/g, "_");
}

/** Every service binding present on env, as the repo names they route for. */
function routableRepos(env) {
  return Object.entries(env)
    .filter(([, value]) => value && typeof value.fetch === "function")
    .map(([name]) => name.toLowerCase().replace(/_/g, "-"))
    .sort();
}

function notFound(env, requested) {
  const available = routableRepos(env);
  const body = [
    `No documentation site is routed at /${requested}.`,
    "",
    "Available:",
    ...available.map((repo) => `  /${repo}/`),
    "",
    "A repository appears here once it has a [[services]] binding in the router's",
    "wrangler.toml and its own docs Worker has been deployed.",
  ].join("\n");
  return new Response(body, {
    status: 404,
    headers: { "content-type": "text/plain; charset=utf-8" },
  });
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const segments = url.pathname.split("/").filter(Boolean);

    // The bare hostname is not a docs site. Redirecting to an arbitrary repo would make one
    // product look like the org's documentation, so it lists instead.
    if (segments.length === 0) {
      return notFound(env, "");
    }

    const [repo, ...rest] = segments;
    const service = env[bindingNameFor(repo)];
    if (!service || typeof service.fetch !== "function") {
      return notFound(env, repo);
    }

    // `/tremvok/setup/` must reach the site Worker as `/setup/`: its assets are laid out
    // from ITS root, and every repo's build is identical in that respect. Stripping here
    // rather than in each site Worker is what keeps the site Worker generic — one template,
    // no per-repo code.
    //
    // The trailing slash is preserved. `/tremvok` and `/tremvok/` are different requests to
    // an assets router: the first 404s where the second serves index.html.
    const inner = new URL(url);
    inner.pathname = "/" + rest.join("/");
    if (url.pathname.endsWith("/") && !inner.pathname.endsWith("/")) {
      inner.pathname += "/";
    }

    // `/tremvok` with no trailing slash: redirect rather than serve, so that the relative
    // links in the page that comes back resolve against `/tremvok/` and not against `/`.
    // Without this every asset on the landing page of every site 404s.
    if (rest.length === 0 && !url.pathname.endsWith("/")) {
      return Response.redirect(`${url.origin}/${repo}/${url.search}`, 301);
    }

    // A new Request rather than passing `request` through: the URL is what changed, and the
    // method, headers and body have to survive unaltered.
    return service.fetch(new Request(inner, request));
  },
};
