/**
 * Dev/prod static-asset wiring.
 *
 * IMPORTANT: This file is imported by `_core/index.ts` at startup. It must
 * NOT have a top-level `import "vite"` or `import "../../vite.config"` —
 * those modules are devDependencies and are intentionally absent from the
 * production runner image (saves ~150 MB and reduces attack surface).
 *
 * Both `setupVite` and the dev-only HTML middleware use **dynamic imports**
 * so that `vite`, `nanoid`, and `vite.config.ts` are only resolved when the
 * server is actually started in development mode.
 *
 * Production simply calls `serveStatic(app)`, which is plain Express
 * static-file serving and has no Vite dependency at all.
 *
 * PATH RESOLUTION: At runtime the bundled output lives at /app/dist/index.js,
 * with the static client at /app/dist/public. We compute paths from the
 * current working directory (cwd) rather than `import.meta.dirname`, because
 * esbuild's bundling collapses the source-tree layout — `dirname` no longer
 * mirrors the original `server/_core/` location.
 */

import express, { type Express } from "express";
import fs from "fs";
import { type Server } from "http";
import path from "path";

/**
 * Resolve the static-build directory in a way that works in both:
 *   - Production: cwd is /app, build is /app/dist/public
 *   - Local dev (after `pnpm build`): cwd is repo root, build is dist/public
 *   - Local dev (without build, vite middleware mode): never called
 */
function resolveDistPath(): string {
  // Primary: relative to cwd. This is correct for both Railway (cwd=/app)
  // and local dev (cwd=repo root).
  const fromCwd = path.resolve(process.cwd(), "dist", "public");
  if (fs.existsSync(fromCwd)) return fromCwd;

  // Fallback: relative to this bundled file. After esbuild bundles the
  // server, this file lives at /app/dist/index.js, so dist/public is
  // a sibling directory.
  const fromBundle = path.resolve(import.meta.dirname, "public");
  return fromBundle;
}

export async function setupVite(app: Express, server: Server) {
  // Lazy imports — these modules are devDependencies, only available in dev.
  // Importing them inside this function (rather than at the top of the file)
  // ensures they are NOT looked up when the production runtime starts.
  const { createServer: createViteServer } = await import("vite");
  const { nanoid } = await import("nanoid");
  const viteConfig = (await import("../../vite.config")).default;

  const serverOptions = {
    middlewareMode: true,
    hmr: { server },
    allowedHosts: true as const,
  };

  const vite = await createViteServer({
    ...viteConfig,
    configFile: false,
    server: serverOptions,
    appType: "custom",
  });

  app.use(vite.middlewares);
  app.use("*", async (req, res, next) => {
    const url = req.originalUrl;

    try {
      const clientTemplate = path.resolve(
        process.cwd(),
        "client",
        "index.html"
      );

      // always reload the index.html file from disk incase it changes
      let template = await fs.promises.readFile(clientTemplate, "utf-8");
      template = template.replace(
        `src="/src/main.tsx"`,
        `src="/src/main.tsx?v=${nanoid()}"`
      );
      const page = await vite.transformIndexHtml(url, template);
      res.status(200).set({ "Content-Type": "text/html" }).end(page);
    } catch (e) {
      vite.ssrFixStacktrace(e as Error);
      next(e);
    }
  });
}

export function serveStatic(app: Express) {
  const distPath = resolveDistPath();

  if (!fs.existsSync(distPath)) {
    console.error(
      `Could not find the build directory: ${distPath}, make sure to run 'pnpm build' first`
    );
    console.error(`cwd: ${process.cwd()}, import.meta.dirname: ${import.meta.dirname}`);
  } else {
    console.log(`[static] Serving client from: ${distPath}`);
  }

  app.use(express.static(distPath));

  // SPA fallback — serve index.html for any non-API route
  app.use("*", (_req, res) => {
    res.sendFile(path.resolve(distPath, "index.html"));
  });
}
