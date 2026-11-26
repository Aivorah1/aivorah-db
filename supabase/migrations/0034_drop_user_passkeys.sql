-- Apply after the auth service has retired the passkey endpoints.
drop table if exists public.user_passkeys restrict;
