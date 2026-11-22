-- Remove the active-referral requirement from withdrawal requests.
-- Preserve the existing pack gate (frontend), maintenance switch, cooldown,
-- payment-method validation, amount limits, balance deduction and pending admin review.

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
    v_last_request_at TIMESTAMPTZ;
    v_minimum NUMERIC;
    v_maximum NUMERIC;
BEGIN
    v_user_id := auth.uid();

    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Login required';
    END IF;

    -- Keep the admin-controlled withdrawal enable/disable switch unchanged.
    IF NOT COALESCE(
        (SELECT c.withdrawals_enabled
         FROM public.atimex_site_control c
         WHERE c.id = 1),
        false
    ) THEN
        RAISE EXCEPTION 'Withdrawals are temporarily paused. Please try again later.';
    END IF;

    IF p_method NOT IN ('bKash', 'Nagad', 'Rocket', 'VISA', 'Upay') THEN
        RAISE EXCEPTION 'Invalid withdrawal method';
    END IF;

    v_minimum := CASE
        WHEN p_method = 'bKash' THEN 100
        WHEN p_method = 'Nagad' THEN 30
        WHEN p_method = 'Upay' THEN 60
        ELSE 20
    END;

    v_maximum := CASE WHEN p_method = 'Upay' THEN 600 ELSE 500 END;

    IF p_amount IS NULL OR p_amount < v_minimum THEN
        RAISE EXCEPTION 'Minimum withdrawal for % is %', p_method, v_minimum;
    END IF;

    IF p_amount > v_maximum THEN
        RAISE EXCEPTION 'Maximum withdrawal for % is %', p_method, v_maximum;
    END IF;

    IF COALESCE(TRIM(p_account_number), '') = ''
       OR COALESCE(TRIM(p_account_name), '') = '' THEN
        RAISE EXCEPTION 'Account details are required';
    END IF;

    IF p_method = 'VISA' AND COALESCE(TRIM(p_bank_name), '') = '' THEN
        RAISE EXCEPTION 'Bank name is required';
    END IF;

    SELECT *
    INTO v_profile
    FROM public.profiles
    WHERE id = v_user_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'User profile not found';
    END IF;

    -- Preserve the existing 24-hour cooldown.
    SELECT MAX(created_at)
    INTO v_last_request_at
    FROM public.withdrawal_requests
    WHERE user_id = v_user_id;

    IF v_last_request_at IS NOT NULL
       AND NOW() < v_last_request_at + INTERVAL '24 hours' THEN
        RAISE EXCEPTION '24-hour withdrawal cooldown active. Please wait until 24 hours have passed.';
    END IF;

    -- No active-referral count or referral-based withdrawal restriction.

    v_balance := COALESCE(
        NULLIF(v_profile.app_data #>> '{progressData,balance}', '')::NUMERIC,
        v_profile.balance,
        0
    );

    IF p_amount > v_balance THEN
        RAISE EXCEPTION 'Insufficient balance';
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
        ),
        updated_at = NOW()
    WHERE id = v_user_id;

    INSERT INTO public.withdrawal_requests (
        user_id, amount, method, account_number, account_name, bank_name, status
    )
    VALUES (
        v_user_id, p_amount, p_method, p_account_number, p_account_name,
        NULLIF(TRIM(p_bank_name), ''), 'pending'
    )
    RETURNING * INTO v_request;

    RETURN v_request;
END;
$function$;
