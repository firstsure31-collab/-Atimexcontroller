import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info, x-supabase-api-version",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function getErrorInfo(error: unknown) {
  const err = error && typeof error === "object" ? error as Record<string, unknown> : {};
  return {
    message: typeof err.message === "string" ? err.message : error instanceof Error ? error.message : String(error),
    code: typeof err.code === "string" ? err.code : null,
    details: typeof err.details === "string" ? err.details : null,
    hint: typeof err.hint === "string" ? err.hint : null,
    stage: typeof err.stage === "string" ? err.stage : null,
  };
}

function throwStageError(stage: string, error: unknown): never {
  const info = getErrorInfo(error);
  const result = new Error(`${stage}: ${info.message}`) as Error & {
    code?: string | null; details?: string | null; hint?: string | null; stage?: string;
  };
  result.code = info.code; result.details = info.details; result.hint = info.hint; result.stage = stage;
  throw result;
}

Deno.serve(async (req) => {
  const reply = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
    status, headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
  if (req.method === "OPTIONS") return reply({ success: true });
  if (req.method !== "POST") return reply({ success: false, error: "POST only" }, 405);

  try {
    const url = Deno.env.get("SUPABASE_URL");
    const anonKey =
      Deno.env.get("SUPABASE_ANON_KEY") ||
      Deno.env.get("SUPABASE_PUBLISHABLE_KEY");
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!url || !anonKey || !serviceKey) {
      return reply({ success: false, error: "Missing Supabase environment variables" }, 500);
    }

    const adminIds = (Deno.env.get("BAN_ADMIN_USER_IDS") || "")
      .split(",").map(x => x.trim()).filter(Boolean);
    const authHeader = req.headers.get("Authorization");
    if (!authHeader?.startsWith("Bearer ")) return reply({ success: false, error: "Login required" }, 401);

    const userClient = createClient(url, anonKey, {
      global: { headers: { Authorization: authHeader } },
      auth: { persistSession: false, autoRefreshToken: false },
    });
    // This client has no persisted session; validate the Bearer JWT explicitly.
    const accessToken = authHeader.slice("Bearer ".length).trim();
    const { data: authData, error: authError } = await userClient.auth.getUser(accessToken);
    if (authError || !authData?.user) {
      return reply({ success: false, error: authError?.message || "Invalid login session" }, 401);
    }
    const caller = authData.user;
    if (!adminIds.includes(caller.id)) return reply({ success: false, error: "Admin permission required" }, 403);

    const adminClient = createClient(url, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });

    let body: Record<string, unknown>;
    try {
      const parsed = await req.json();
      if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) throw new Error("Invalid request body");
      body = parsed as Record<string, unknown>;
    } catch {
      return reply({ success: false, error: "Invalid JSON request body" }, 400);
    }
    const action = typeof body.action === "string" ? body.action.trim().toLowerCase() : "";

    if (action === "list") {
      const users: Array<{ id: string; email: string; banned_until: string | null; is_active: boolean }> = [];
      const perPage = 500;
      for (let page = 1; page <= 100; page++) {
        const { data: authResult, error: listError } = await adminClient.auth.admin.listUsers({ page, perPage });
        if (listError) throwStageError("AUTH_USER_LIST", listError);
        const authUsers = authResult?.users || [];
        const userIds = authUsers.map(user => user.id);
        const activeMap = new Map<string, boolean>();
        if (userIds.length) {
          const { data: statusRows, error: statusError } = await adminClient.rpc("admin_get_profile_activation_status", { p_user_ids: userIds });
          if (statusError) throwStageError("ACTIVATION_STATUS_RPC", statusError);
          for (const row of statusRows || []) activeMap.set(row.id, row.is_active === true);
        }
        users.push(...authUsers.map(user => ({
          id: user.id, email: user.email || "", banned_until: user.banned_until || null,
          is_active: activeMap.get(user.id) === true,
        })));
        if (authUsers.length < perPage) break;
      }
      return reply({ success: true, count: users.length, users });
    }

    if (action === "ban" || action === "unban") {
      const userId = typeof body.user_id === "string" ? body.user_id.trim() : "";
      if (!userId) return reply({ success: false, error: "User ID required" }, 400);
      if (userId === caller.id || adminIds.includes(userId)) {
        return reply({ success: false, error: "Admin accounts cannot be banned from this function" }, 400);
      }
      const { data, error } = await adminClient.auth.admin.updateUserById(userId, {
        ban_duration: action === "ban" ? "876000h" : "none",
      });
      if (error) throwStageError("BAN_UNBAN_UPDATE", error);
      if (!data?.user) throw new Error("Updated user was not returned");
      return reply({ success: true, action, user_id: data.user.id, email: data.user.email || "" });
    }

    if (action === "ban_all" || action === "unban_all") {
      let updated = 0;
      let failed = 0;
      const failures: string[] = [];
      const perPage = 500;
      for (let page = 1; page <= 100; page++) {
        const { data: authResult, error: listError } = await adminClient.auth.admin.listUsers({ page, perPage });
        if (listError) throwStageError("BULK_AUTH_USER_LIST", listError);
        const authUsers = authResult?.users || [];
        for (const user of authUsers) {
          if (adminIds.includes(user.id)) continue;
          const { error } = await adminClient.auth.admin.updateUserById(user.id, {
            ban_duration: action === "ban_all" ? "876000h" : "none",
          });
          if (error) {
            failed++;
            if (failures.length < 10) failures.push(user.email || user.id);
          } else updated++;
        }
        if (authUsers.length < perPage) break;
      }
      return reply({
        success: failed === 0, action, updated, failed, failures,
        error: failed ? "Some accounts could not be updated. Check failures and retry." : undefined,
      }, failed ? 207 : 200);
    }

    if (action === "maintenance_on" || action === "maintenance_off") {
      const enabled = action === "maintenance_on";
      const { error } = await adminClient.from("atimex_site_control").upsert({
        id: 1,
        maintenance_enabled: enabled,
        maintenance_message: "ATIMEX-এ update চলছে। কিছুক্ষণ পর আবার চেষ্টা করুন।",
        updated_at: new Date().toISOString(),
        updated_by: caller.id,
      }, { onConflict: "id" });
      if (error) throwStageError("MAINTENANCE_SETTINGS_UPDATE", error);
      return reply({
        success: true, action, maintenance_enabled: enabled,
        message: "ATIMEX-এ update চলছে। কিছুক্ষণ পর আবার চেষ্টা করুন।",
      });
    }

    return reply({ success: false, error: "Invalid action. Use list, ban, unban, ban_all, unban_all, maintenance_on, or maintenance_off." }, 400);
  } catch (error) {
    const info = getErrorInfo(error);
    console.error("BAN USER FUNCTION ERROR:", info);
    return reply({ success: false, error: info.message, code: info.code, details: info.details, hint: info.hint, stage: info.stage }, 500);
  }
});
