-- Fix activation referral processing.
-- Actual public.referrals schema has: id, referrer_id, referred_user_id,
-- status, created_at, activated_at. Do not reference payment_request_id/referral_code.
-- Each referred account receives at most one referral relationship and one ৳50 bonus.

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
        50,
        'Active referral bonus - ৳50'
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
            balance = v_balance + 50,
            app_data = jsonb_set(
                COALESCE(p.app_data, '{}'::jsonb),
                '{progressData}',
                COALESCE(p.app_data->'progressData', '{}'::jsonb)
                    || jsonb_build_object(
                        'balance', v_balance + 50,
                        'referralEarned', v_referral_earned + 50
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

-- Do not expose the wallet-credit helper as a client-callable RPC.
REVOKE ALL ON FUNCTION public.apply_referral_activation_bonus(uuid, text)
FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.process_approved_activation_referral()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
    IF NEW.request_type <> 'activation'
       OR NEW.status <> 'approved'
       OR OLD.status IS NOT DISTINCT FROM NEW.status THEN
        RETURN NEW;
    END IF;

    IF NULLIF(TRIM(COALESCE(NEW.referral_code, '')), '') IS NULL THEN
        RETURN NEW;
    END IF;

    -- Errors intentionally propagate so the approval transaction rolls back
    -- instead of showing success while silently dropping the referral bonus.
    PERFORM public.apply_referral_activation_bonus(
        NEW.user_id,
        NEW.referral_code
    );

    RETURN NEW;
END;
$function$;


-- Keep both active flags in sync. Some app readers use progressData.isActive,
-- while older backend functions read the root-level is_active flag.
CREATE OR REPLACE FUNCTION public.admin_review_payment_request(
    p_request_id uuid,
    p_action text
)
RETURNS public.payment_requests
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_request public.payment_requests;
    v_updated_count integer := 0;
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM public.atimex_admins
        WHERE user_id = auth.uid()
    ) THEN
        RAISE EXCEPTION 'Not authorized';
    END IF;

    IF p_action NOT IN ('approved', 'rejected') THEN
        RAISE EXCEPTION 'Invalid action';
    END IF;

    SELECT *
    INTO v_request
    FROM public.payment_requests
    WHERE id = p_request_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Request not found';
    END IF;

    IF v_request.status <> 'pending' THEN
        RAISE EXCEPTION 'Request already reviewed';
    END IF;

    IF p_action = 'approved' THEN
        IF v_request.request_type = 'deposit' THEN
            UPDATE public.profiles
            SET
                balance = COALESCE(balance, 0) + v_request.amount,
                app_data = jsonb_set(
                    COALESCE(app_data, '{}'::jsonb),
                    '{progressData}',
                    COALESCE(app_data->'progressData', '{}'::jsonb)
                    || jsonb_build_object(
                        'balance',
                        COALESCE(
                            NULLIF(app_data #>> '{progressData,balance}', '')::numeric,
                            0
                        ) + v_request.amount
                    ),
                    true
                ),
                updated_at = now()
            WHERE id = v_request.user_id;

            GET DIAGNOSTICS v_updated_count = ROW_COUNT;

        ELSIF v_request.request_type = 'activation' THEN
            UPDATE public.profiles
            SET
                app_data = jsonb_set(
                    jsonb_set(
                        COALESCE(app_data, '{}'::jsonb),
                        '{is_active}',
                        'true'::jsonb,
                        true
                    ),
                    '{progressData}',
                    COALESCE(app_data->'progressData', '{}'::jsonb)
                        || jsonb_build_object('isActive', true),
                    true
                ),
                updated_at = now()
            WHERE id = v_request.user_id;

            GET DIAGNOSTICS v_updated_count = ROW_COUNT;

        ELSIF v_request.request_type = 'vip_package' THEN
            IF v_request.package_id IS NULL
               OR v_request.package_duration_days IS NULL
               OR v_request.package_daily_amount IS NULL THEN
                RAISE EXCEPTION 'Package information is incomplete';
            END IF;
        ELSE
            RAISE EXCEPTION 'Unknown request type: %', v_request.request_type;
        END IF;

        IF v_request.request_type <> 'vip_package'
           AND v_updated_count = 0 THEN
            RAISE EXCEPTION 'User profile not found: %', v_request.user_id;
        END IF;
    END IF;

    UPDATE public.payment_requests
    SET
        status = p_action,
        reviewed_at = now(),
        reviewed_by = auth.uid()
    WHERE id = p_request_id
    RETURNING * INTO v_request;

    RETURN v_request;
END;
$function$;

-- Repair previously approved activations that had a valid referral code but
-- were skipped by the old trigger. Only currently active referred accounts are
-- eligible, and existing ledger entries are never credited twice.
DO $$
DECLARE
    v_row record;
BEGIN
    FOR v_row IN
        SELECT DISTINCT ON (pr.user_id)
            pr.user_id,
            pr.referral_code
        FROM public.payment_requests pr
        JOIN public.referral_codes rc
          ON UPPER(TRIM(rc.code)) = UPPER(TRIM(pr.referral_code))
        JOIN public.profiles referred_profile
          ON referred_profile.id = pr.user_id
        LEFT JOIN public.referrals existing_referral
          ON existing_referral.referred_user_id = pr.user_id
        WHERE pr.request_type = 'activation'
          AND pr.status = 'approved'
          AND NULLIF(TRIM(COALESCE(pr.referral_code, '')), '') IS NOT NULL
          AND rc.user_id <> pr.user_id
          AND (
              existing_referral.id IS NULL
              OR existing_referral.referrer_id = rc.user_id
          )
          AND (
              LOWER(COALESCE(referred_profile.app_data #>> '{progressData,isActive}', 'false')) IN ('true', '1')
              OR LOWER(COALESCE(referred_profile.app_data ->> 'is_active', 'false')) IN ('true', '1')
              OR LOWER(COALESCE(referred_profile.app_data ->> 'isActive', 'false')) IN ('true', '1')
          )
        ORDER BY
            pr.user_id,
            (existing_referral.id IS NOT NULL) DESC,
            pr.reviewed_at ASC NULLS LAST,
            pr.created_at ASC
    LOOP
        PERFORM public.apply_referral_activation_bonus(
            v_row.user_id,
            v_row.referral_code
        );
    END LOOP;
END;
$$;
