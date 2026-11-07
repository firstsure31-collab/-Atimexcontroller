CREATE OR REPLACE FUNCTION public.submit_withdrawal_request(
    p_amount numeric,
    p_method text,
    p_account_number text,
    p_account_name text,
    p_bank_name text DEFAULT NULL::text
)
RETURNS public.withdrawal_requests
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_user_id UUID;
    v_profile public.profiles;
    v_balance NUMERIC;
    v_new_balance NUMERIC;
    v_request public.withdrawal_requests;
    v_approved_withdrawal_count INTEGER := 0;
    v_active_referral_count INTEGER := 0;
    v_referral_unlocked BOOLEAN := FALSE;
BEGIN
    v_user_id := auth.uid();

    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Login required';
    END IF;

    IF p_amount IS NULL OR p_amount < 20 THEN
        RAISE EXCEPTION 'Minimum withdrawal is 20';
    END IF;

    IF p_method NOT IN ('bKash', 'Nagad', 'Rocket', 'VISA') THEN
        RAISE EXCEPTION 'Invalid withdrawal method';
    END IF;

    IF COALESCE(TRIM(p_account_number), '') = ''
       OR COALESCE(TRIM(p_account_name), '') = '' THEN
        RAISE EXCEPTION 'Account details are required';
    END IF;

    IF p_method = 'VISA' AND COALESCE(TRIM(p_bank_name), '') = '' THEN
        RAISE EXCEPTION 'Bank name is required';
    END IF;

    -- Lock the user's profile so simultaneous requests cannot bypass the one-time unlock.
    SELECT *
    INTO v_profile
    FROM public.profiles
    WHERE id = v_user_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'User profile not found';
    END IF;

    v_balance := COALESCE(
        NULLIF(v_profile.app_data #>> '{progressData,balance}', '')::NUMERIC,
        v_profile.balance,
        0
    );

    IF p_amount > v_balance THEN
        RAISE EXCEPTION 'Insufficient balance';
    END IF;

    -- The first approved withdrawal is free. Before the next withdrawal,
    -- one active referral is required exactly once.
    SELECT COUNT(*)::INTEGER
    INTO v_approved_withdrawal_count
    FROM public.withdrawal_requests
    WHERE user_id = v_user_id
      AND status = 'approved';

    v_referral_unlocked :=
        COALESCE(v_profile.app_data @> '{"withdrawReferralUnlocked": true}'::jsonb, FALSE);

    IF v_approved_withdrawal_count >= 1 AND NOT v_referral_unlocked THEN
        SELECT COUNT(*)::INTEGER
        INTO v_active_referral_count
        FROM public.profiles
        WHERE app_data->>'referredBy' = v_user_id::TEXT
          AND is_active = TRUE;

        IF v_active_referral_count < 1 THEN
            RAISE EXCEPTION 'One active referral is required for your second withdrawal';
        END IF;

        -- Persist the unlock permanently for this account.
        v_referral_unlocked := TRUE;
    END IF;

    v_new_balance := v_balance - p_amount;

    UPDATE public.profiles
    SET
        balance = v_new_balance,
        app_data = jsonb_set(
            COALESCE(app_data, '{}'::jsonb),
            '{progressData}',
            COALESCE(app_data->'progressData', '{}'::jsonb)
                || jsonb_build_object('balance', v_new_balance),
            true
        ) || CASE
            WHEN v_referral_unlocked
                THEN jsonb_build_object('withdrawReferralUnlocked', TRUE)
            ELSE '{}'::jsonb
        END,
        updated_at = NOW()
    WHERE id = v_user_id;

    INSERT INTO public.withdrawal_requests (
        user_id,
        amount,
        method,
        account_number,
        account_name,
        bank_name,
        status
    )
    VALUES (
        v_user_id,
        p_amount,
        p_method,
        p_account_number,
        p_account_name,
        NULLIF(TRIM(p_bank_name), ''),
        'pending'
    )
    RETURNING * INTO v_request;

    RETURN v_request;
END;
$function$;
