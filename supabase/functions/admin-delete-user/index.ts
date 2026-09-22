import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

Deno.serve(async (req) => {
  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) return new Response(JSON.stringify({ error: "Unauthorized" }), { status: 401 });

    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!supabaseUrl || !anonKey || !serviceKey) throw new Error("Supabase function environment is incomplete.");

    const userClient = createClient(supabaseUrl, anonKey, { global: { headers: { Authorization: authHeader } } });
    const { data: { user: caller }, error: callerError } = await userClient.auth.getUser();
    if (callerError || !caller) return new Response(JSON.stringify({ error: "Unauthorized" }), { status: 401 });

    const { data: profile, error: profileError } = await userClient
      .from("staff_profiles").select("account_status,system_role").eq("id", caller.id).single();
    if (profileError || profile?.account_status !== "approved" ||
        !["ceo_chairperson","coo_treasurer","executive_secretary","super_admin"].includes(profile.system_role)) {
      return new Response(JSON.stringify({ error: "Admin approval required." }), { status: 403 });
    }

    const { user_id } = await req.json();
    if (!user_id || user_id === caller.id) {
      return new Response(JSON.stringify({ error: "Invalid target user." }), { status: 400 });
    }

    const adminClient = createClient(supabaseUrl, serviceKey);
    const { error } = await adminClient.auth.admin.deleteUser(user_id);
    if (error) throw error;

    return new Response(JSON.stringify({ success: true }), {
      headers: { "Content-Type": "application/json" }, status: 200
    });
  } catch (error) {
    return new Response(JSON.stringify({ error: error.message ?? "Delete failed." }), {
      headers: { "Content-Type": "application/json" }, status: 500
    });
  }
});