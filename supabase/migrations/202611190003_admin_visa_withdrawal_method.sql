-- Ensure withdrawal_requests accepts VISA (and existing providers including Upay).
-- This does not enable VISA in the user wallet; it only allows/administers records.
ALTER TABLE public.withdrawal_requests
DROP CONSTRAINT IF EXISTS withdrawal_requests_method_check;

ALTER TABLE public.withdrawal_requests
ADD CONSTRAINT withdrawal_requests_method_check
CHECK (
  method = ANY (
    ARRAY['bKash'::text, 'Nagad'::text, 'Rocket'::text, 'Upay'::text, 'VISA'::text]
  )
);
