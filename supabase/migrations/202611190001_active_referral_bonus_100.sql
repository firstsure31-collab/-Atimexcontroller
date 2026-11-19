-- Set the one-time active referral reward to ৳100 for future activations.
-- Existing ledger entries are intentionally unchanged and are not credited again.
CREATE OR REPLACE FUNCTION public.apply_referral_activation_bonus(
    p_referred_user_id uuid,
    p_referral_code text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_code text;
    v_referrer_id uuid;
    v_referral_id uuid;
    v_ledger_id uuid;
    v_balance numeric := 0;
    v_referral_earned numeric := 0;
    v_referred_active boolean := false;
BEGIN
    v_code := UPPER(TRIM(COALESCE(p_referral_code, '')));
    IF v_code = '' THEN
        RETURN false;
    END IF;

    IF p_referred_user_id IS NULL THEN
        RAISE EXCEPTION 'Referred user ID is missing';
    END IF;

    SELECT rc.user_id
    INTO v_referrer_id
    FROM public.referral_codes rc
    WHERE UPPER(TRIM(rc.code)) = v_code
    LIMIT 1;

    IF v_referrer_id IS NULL THEN
        RAISE EXCEPTION 'Invalid referral code: %', v_code;
    END IF;

    IF v_referrer_id = p_referred_user_id THEN
        RAISE EXCEPTION 'Self referral is not allowed';
    END IF;

    SELECT (
        LOWER(COALESCE(p.app_data #>> '{progressData,isActive}', 'false')) IN ('true', '1')
        OR LOWER(COALESCE(p.app_data ->> 'is_active', 'false')) IN ('true', '1')
        OR LOWER(COALESCE(p.app_data ->> 'isActive', 'false')) IN ('true', '1')
    )
    INTO v_referred_active
    FROM public.profiles p
    WHERE p.id = p_referred_user_id;

    IF NOT COALESCE(v_referred_active, false) THEN
        RAISE EXCEPTION 'Referred account is not active yet';
    END IF;

    -- Use only columns that exist in the current referrals table.
    -- Preserve an already-linked referrer; never reassign an account.
    INSERT INTO public.referrals (
        referrer_id,
        referred_user_id,
        status,
        activated_at
    )
    VALUES (
        v_referrer_id,
        p_referred_user_id,
        'active',
        NOW()
    )
    ON CONFLICT (referred_user_id) DO UPDATE
    SET
        status = 'active',
        activated_at = COALESCE(public.referrals.activated_at, NOW())
    WHERE public.referrals.referrer_id = EXCLUDED.referrer_id
    RETURNING id INTO v_referral_id;

    IF v_referral_id IS NULL THEN
        RAISE EXCEPTION 'This account is already linked to a different referrer';
    END IF;

    -- The unique referral_id constraint prevents duplicate ledger entries/bonuses.
    INSERT INTO public.referral_bonus_ledger (
        user_id,
        referral_id,
        amount,
        description
    )
    VALUES (
        v_referrer_id,
        v_referral_id,
        100,
        'Active referral bonus - ৳100'
    )
    ON CONFLICT (referral_id) DO NOTHING
    RETURNING id INTO v_ledger_id;

    -- Credit wallet only when this call created the one-time ledger entry.
    IF v_ledger_id IS NOT NULL THEN
        SELECT
            COALESCE(
                NULLIF(p.app_data #>> '{progressData,balance}', '')::numeric,
                p.balance,
                0
            ),
            COALESCE(
                NULLIF(p.app_data #>> '{progressData,referralEarned}', '')::numeric,
                0
            )
        INTO v_balance, v_referral_earned
        FROM public.profiles p
        WHERE p.id = v_referrer_id
        FOR UPDATE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Referrer profile not found: %', v_referrer_id;
        END IF;

        UPDATE public.profiles p
        SET
            balance = v_balance + 100,
            app_data = jsonb_set(
                COALESCE(p.app_data, '{}'::jsonb),
                '{progressData}',
                COALESCE(p.app_data->'progressData', '{}'::jsonb)
                    || jsonb_build_object(
                        'balance', v_balance + 100,
                        'referralEarned', v_referral_earned + 100
                    ),
                true
            ),
            updated_at = NOW()
        WHERE p.id = v_referrer_id;
    END IF;

    UPDATE public.profiles p
    SET active_referrals_count = (
        SELECT COUNT(*)::integer
        FROM public.referrals r
        WHERE r.referrer_id = v_referrer_id
          AND r.status = 'active'
    )
    WHERE p.id = v_referrer_id;

    RETURN v_ledger_id IS NOT NULL;
END;
$function$;


-- Keep the helper private; activation approval trigger invokes it as SECURITY DEFINER.
REVOKE ALL ON FUNCTION public.apply_referral_activation_bonus(uuid, text)
FROM PUBLIC, anon, authenticated;
