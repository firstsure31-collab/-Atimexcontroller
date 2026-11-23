-- Repair monthly Daily Claim balance synchronization.
-- Claims remain one-per-user-per-month/day; existing claim history is preserved.
-- The RPC now updates both profiles.balance and app_data.progressData atomically.
-- The frontend must not perform a second whole-profile upsert after the RPC.

CREATE OR REPLACE FUNCTION public.claim_monthly_daily_reward()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $function$
DECLARE
    v_user uuid := auth.uid();
    v_now timestamptz := now();
    v_today date := (now() AT TIME ZONE 'Asia/Dhaka')::date;
    v_month date;
    v_day integer;
    v_profile jsonb;
    v_profile_balance numeric(12,2);
    v_active boolean := false;
    v_amount numeric(12,2);
    v_claim_id bigint;
    v_balance numeric(12,2);
    v_total numeric(12,2);
    v_current_balance numeric(12,2);
    v_current_total numeric(12,2);
    v_claimed integer[];
BEGIN
    IF v_user IS NULL THEN
        RAISE EXCEPTION 'Login required';
    END IF;

    v_month := date_trunc('month', v_today)::date;
    v_day := LEAST(EXTRACT(DAY FROM v_today)::integer, 30);

    -- Lock the profile so concurrent claims cannot double-credit.
    SELECT
        COALESCE(p.app_data, '{}'::jsonb),
        COALESCE(p.balance, 0)
    INTO
        v_profile,
        v_profile_balance
    FROM public.profiles p
    WHERE p.id = v_user
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Profile not found';
    END IF;

    -- Support both current and legacy active flags.
    v_active :=
        LOWER(COALESCE(v_profile #>> '{progressData,isActive}', 'false')) IN ('true', '1')
        OR LOWER(COALESCE(v_profile ->> 'is_active', 'false')) IN ('true', '1')
        OR LOWER(COALESCE(v_profile ->> 'isActive', 'false')) IN ('true', '1');

    IF NOT v_active THEN
        RAISE EXCEPTION 'Account must be active to claim';
    END IF;

    -- Sum only approved VIP packages that have not expired.
    SELECT COALESCE(SUM(pr.package_daily_amount), 0)
    INTO v_amount
    FROM public.payment_requests pr
    WHERE pr.user_id = v_user
      AND pr.request_type = 'vip_package'
      AND pr.status = 'approved'
      AND COALESCE(pr.package_daily_amount, 0) > 0
      AND (
          COALESCE(pr.package_duration_days, 0) <= 0
          OR v_now < (
              COALESCE(pr.reviewed_at, pr.created_at)
              + pr.package_duration_days * INTERVAL '1 day'
          )
      );

    -- Activated members without an active package receive the free daily amount.
    IF COALESCE(v_amount, 0) <= 0 THEN
        v_amount := 20;
    END IF;

    -- A unique (user_id, claim_month, claim_day) key prevents duplicate credit.
    INSERT INTO public.atimex_monthly_daily_claims
        (user_id, claim_month, claim_day, amount, created_at)
    VALUES
        (v_user, v_month, v_day, v_amount, v_now)
    ON CONFLICT (user_id, claim_month, claim_day) DO NOTHING
    RETURNING id INTO v_claim_id;

    IF v_claim_id IS NULL THEN
        SELECT COALESCE(ARRAY_AGG(c.claim_day ORDER BY c.claim_day), '{}')
        INTO v_claimed
        FROM public.atimex_monthly_daily_claims c
        WHERE c.user_id = v_user
          AND c.claim_month = v_month;

        v_current_balance := COALESCE(
            NULLIF(v_profile #>> '{progressData,balance}', '')::numeric,
            v_profile_balance,
            0
        );
        v_current_total := COALESCE(
            NULLIF(v_profile #>> '{progressData,totalEarned}', '')::numeric,
            0
        );

        RETURN jsonb_build_object(
            'claimed', false,
            'message', 'Already claimed today',
            'balance', v_current_balance,
            'total_earned', v_current_total,
            'month_key', to_char(v_month, 'YYYY-MM'),
            'month_label', to_char(v_month, 'FMMonth YYYY'),
            'day_number', v_day,
            'claimed_days', v_claimed,
            'daily_amount', v_amount,
            'can_claim', false
        );
    END IF;

    -- Prefer the authoritative app_data balance, falling back to profiles.balance.
    v_current_balance := COALESCE(
        NULLIF(v_profile #>> '{progressData,balance}', '')::numeric,
        v_profile_balance,
        0
    );
    v_current_total := COALESCE(
        NULLIF(v_profile #>> '{progressData,totalEarned}', '')::numeric,
        0
    );

    v_balance := v_current_balance + v_amount;
    v_total := v_current_total + v_amount;

    -- Update both balance representations in the same transaction as the claim row.
    UPDATE public.profiles p
    SET
        balance = v_balance,
        app_data = jsonb_set(
            jsonb_set(
                COALESCE(p.app_data, '{}'::jsonb),
                '{progressData,balance}',
                to_jsonb(v_balance),
                true
            ),
            '{progressData,totalEarned}',
            to_jsonb(v_total),
            true
        ),
        updated_at = v_now
    WHERE p.id = v_user;

    SELECT COALESCE(ARRAY_AGG(c.claim_day ORDER BY c.claim_day), '{}')
    INTO v_claimed
    FROM public.atimex_monthly_daily_claims c
    WHERE c.user_id = v_user
      AND c.claim_month = v_month;

    RETURN jsonb_build_object(
        'claimed', true,
        'amount', v_amount,
        'balance', v_balance,
        'total_earned', v_total,
        'month_key', to_char(v_month, 'YYYY-MM'),
        'month_label', to_char(v_month, 'FMMonth YYYY'),
        'day_number', v_day,
        'claimed_days', v_claimed,
        'daily_amount', v_amount,
        'can_claim', false
    );
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_monthly_daily_claim_status()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $function$
DECLARE
    v_user uuid := auth.uid();
    v_today date := (now() AT TIME ZONE 'Asia/Dhaka')::date;
    v_month date;
    v_day integer;
    v_profile jsonb;
    v_active boolean := false;
    v_amount numeric(12,2);
    v_claimed integer[];
BEGIN
    IF v_user IS NULL THEN
        RAISE EXCEPTION 'Login required';
    END IF;

    v_month := date_trunc('month', v_today)::date;
    v_day := LEAST(EXTRACT(DAY FROM v_today)::integer, 30);

    SELECT COALESCE(p.app_data, '{}'::jsonb)
    INTO v_profile
    FROM public.profiles p
    WHERE p.id = v_user;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Profile not found';
    END IF;

    v_active :=
        LOWER(COALESCE(v_profile #>> '{progressData,isActive}', 'false')) IN ('true', '1')
        OR LOWER(COALESCE(v_profile ->> 'is_active', 'false')) IN ('true', '1')
        OR LOWER(COALESCE(v_profile ->> 'isActive', 'false')) IN ('true', '1');

    SELECT COALESCE(SUM(pr.package_daily_amount), 0)
    INTO v_amount
    FROM public.payment_requests pr
    WHERE pr.user_id = v_user
      AND pr.request_type = 'vip_package'
      AND pr.status = 'approved'
      AND COALESCE(pr.package_daily_amount, 0) > 0
      AND (
          COALESCE(pr.package_duration_days, 0) <= 0
          OR now() < (
              COALESCE(pr.reviewed_at, pr.created_at)
              + pr.package_duration_days * INTERVAL '1 day'
          )
      );

    IF COALESCE(v_amount, 0) <= 0 THEN
        v_amount := 20;
    END IF;

    SELECT COALESCE(ARRAY_AGG(c.claim_day ORDER BY c.claim_day), '{}')
    INTO v_claimed
    FROM public.atimex_monthly_daily_claims c
    WHERE c.user_id = v_user
      AND c.claim_month = v_month;

    RETURN jsonb_build_object(
        'month_key', to_char(v_month, 'YYYY-MM'),
        'month_label', to_char(v_month, 'FMMonth YYYY'),
        'day_number', v_day,
        'claimed_days', v_claimed,
        'daily_amount', v_amount,
        'can_claim', v_active AND NOT (v_day = ANY(v_claimed))
    );
END;
$function$;

REVOKE ALL ON FUNCTION public.claim_monthly_daily_reward() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.claim_monthly_daily_reward() TO authenticated;

REVOKE ALL ON FUNCTION public.get_monthly_daily_claim_status() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_monthly_daily_claim_status() TO authenticated;
