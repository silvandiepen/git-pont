/** CORS handling locked to the configured gitKanban origin(s), with credentials. */

import { allowedOrigins, type Env } from "./env.js";

export function resolveOrigin(request: Request, env: Env): string | undefined {
  const origin = request.headers.get("Origin");
  if (!origin) return undefined;
  return allowedOrigins(env).includes(origin) ? origin : undefined;
}

export function corsHeaders(origin: string | undefined): Record<string, string> {
  if (!origin) return {};
  return {
    "Access-Control-Allow-Origin": origin,
    "Access-Control-Allow-Credentials": "true",
    "Access-Control-Allow-Methods": "GET, POST, PATCH, DELETE, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type, Authorization",
    "Access-Control-Max-Age": "86400",
    Vary: "Origin",
  };
}

export function preflight(request: Request, env: Env): Response {
  const origin = resolveOrigin(request, env);
  return new Response(null, { status: 204, headers: corsHeaders(origin) });
}

/** Merge CORS headers onto an existing response for the given request. */
export function withCors(response: Response, request: Request, env: Env): Response {
  const origin = resolveOrigin(request, env);
  const headers = new Headers(response.headers);
  for (const [key, value] of Object.entries(corsHeaders(origin))) {
    headers.set(key, value);
  }
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}
