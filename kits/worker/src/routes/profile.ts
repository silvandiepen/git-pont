/** Per-user profile endpoints (color mode, recent repos, app preferences). */

import type { Env } from "../env.js";
import { errorResponse, json } from "../http.js";
import { ProfileStore, type UserProfile } from "../stores/profile-store.js";
import type { ResolvedSession } from "../session.js";

/** GET /me/profile */
export async function getProfile(env: Env, session: ResolvedSession): Promise<Response> {
  const profile = await new ProfileStore(env.PROFILES).get(session.record.userId);
  return json(profile);
}

/** PATCH /me/profile — shallow-merge the provided fields. */
export async function patchProfile(
  request: Request,
  env: Env,
  session: ResolvedSession,
): Promise<Response> {
  let body: Partial<UserProfile>;
  try {
    body = (await request.json()) as Partial<UserProfile>;
  } catch {
    return errorResponse(400, "Invalid JSON body");
  }
  const patch: Partial<UserProfile> = {};
  if (body.colorMode !== undefined) patch.colorMode = body.colorMode;
  if (Array.isArray(body.recentRepos)) patch.recentRepos = body.recentRepos;
  if (body.preferences && typeof body.preferences === "object") {
    patch.preferences = body.preferences;
  }
  const updated = await new ProfileStore(env.PROFILES).patch(session.record.userId, patch);
  return json(updated);
}
