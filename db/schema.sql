\restrict dbmate

-- Dumped from database version 18.6 (Debian 18.6-1.pgdg13+2)
-- Dumped by pg_dump version 18.6

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: auth; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA auth;


--
-- Name: extensions; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA extensions;


--
-- Name: private; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA private;


--
-- Name: citext; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS citext WITH SCHEMA extensions;


--
-- Name: EXTENSION citext; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION citext IS 'data type for case-insensitive character strings';


--
-- Name: pgcrypto; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;


--
-- Name: EXTENSION pgcrypto; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pgcrypto IS 'cryptographic functions';


--
-- Name: manga_status; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.manga_status AS ENUM (
    'reading',
    'completed',
    'on_hold',
    'dropped',
    'plan_to_read'
);


--
-- Name: token_for(uuid); Type: FUNCTION; Schema: auth; Owner: -
--

CREATE FUNCTION auth.token_for(account_id uuid) RETURNS jsonb
    LANGUAGE plpgsql STABLE
    SET search_path TO 'extensions'
    AS $$
DECLARE
    cfg auth.jwt_config;
    signing_input text;
BEGIN
    SELECT * INTO cfg FROM auth.jwt_config;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'JWT is not configured; run make configure';
    END IF;
    signing_input := private.base64url(convert_to('{"alg":"HS256","typ":"JWT"}', 'utf8')) || '.'
        || private.base64url(convert_to(jsonb_build_object(
               'sub', account_id,
               'role', 'authenticated',
               -- floor: a rounded-up iat lands in the future and PostgREST rejects it
               'iat', floor(extract(epoch FROM now()))::bigint,
               'exp', floor(extract(epoch FROM now() + cfg.ttl))::bigint)::text, 'utf8'));
    RETURN jsonb_build_object('token',
        signing_input || '.' || private.base64url(hmac(signing_input, cfg.secret, 'sha256')));
END
$$;


--
-- Name: base64url(bytea); Type: FUNCTION; Schema: private; Owner: -
--

CREATE FUNCTION private.base64url(data bytea) RETURNS text
    LANGUAGE sql IMMUTABLE
    AS $$
    SELECT rtrim(translate(encode(data, 'base64'), E'+/\n', '-_'), '=')
$$;


--
-- Name: current_user_id(); Type: FUNCTION; Schema: private; Owner: -
--

CREATE FUNCTION private.current_user_id() RETURNS uuid
    LANGUAGE sql STABLE
    AS $$
    SELECT (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')::uuid
$$;


--
-- Name: is_valid_sites(jsonb); Type: FUNCTION; Schema: private; Owner: -
--

CREATE FUNCTION private.is_valid_sites(sites jsonb) RETURNS boolean
    LANGUAGE sql IMMUTABLE
    AS $_$
    SELECT CASE WHEN jsonb_typeof(sites) <> 'array' THEN false ELSE (
        -- coalesce per element: a missing key yields NULL, which bool_and would skip
        SELECT coalesce(bool_and(coalesce(
                   jsonb_typeof(e) = 'object'
                   AND e->>'type' IN ('primary', 'alt')
                   AND jsonb_typeof(e->'url') = 'string'
                   AND e->>'url' ~* '^https?://\S+$', false)), true)
               AND count(*) FILTER (WHERE e->>'type' = 'primary') <= 1
        FROM jsonb_array_elements(sites) AS e
    ) END
$_$;


--
-- Name: set_updated_at(); Type: FUNCTION; Schema: private; Owner: -
--

CREATE FUNCTION private.set_updated_at() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END
$$;


--
-- Name: login(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.login(email text, password text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'extensions'
    AS $_$
DECLARE
    acct auth.account;
BEGIN
    SELECT * INTO acct FROM auth.account a WHERE a.email = login.email::citext;
    -- Unknown emails still pay for a bcrypt compare, so timing doesn't reveal which exist.
    IF acct.id IS NULL
       OR crypt(coalesce(password, ''), coalesce(acct.password_hash,
              '$2a$12$fbWcy8L44d6HWdNN5V//9uaDuRP/ybPUPP1R6b818a9V/bGlhPdfi')) <> acct.password_hash THEN
        RAISE SQLSTATE 'PT401' USING MESSAGE = 'invalid email or password';
    END IF;
    RETURN auth.token_for(acct.id);
END
$_$;


--
-- Name: signup(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.signup(email text, password text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'extensions'
    AS $$
DECLARE
    new_id uuid;
BEGIN
    IF email IS NULL OR password IS NULL THEN
        RAISE EXCEPTION 'email and password are required' USING ERRCODE = '22023';
    END IF;
    -- bcrypt silently ignores bytes past 72
    IF length(password) < 12 OR octet_length(password) > 72 THEN
        RAISE EXCEPTION 'password must be at least 12 characters and at most 72 bytes' USING ERRCODE = '22023';
    END IF;
    INSERT INTO auth.account (email, password_hash)
    VALUES (signup.email, crypt(password, gen_salt('bf', 12)))
    RETURNING id INTO new_id;
    RETURN auth.token_for(new_id);
END
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: account; Type: TABLE; Schema: auth; Owner: -
--

CREATE TABLE auth.account (
    id uuid DEFAULT uuidv7() NOT NULL,
    email extensions.citext NOT NULL,
    password_hash text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT account_email_check CHECK ((email OPERATOR(extensions.~) '^[^@\s]+@[^@\s]+\.[^@\s]+$'::extensions.citext))
);


--
-- Name: jwt_config; Type: TABLE; Schema: auth; Owner: -
--

CREATE TABLE auth.jwt_config (
    singleton boolean DEFAULT true NOT NULL,
    secret text NOT NULL,
    ttl interval NOT NULL,
    CONSTRAINT jwt_config_secret_check CHECK ((length(secret) >= 32)),
    CONSTRAINT jwt_config_singleton_check CHECK (singleton),
    CONSTRAINT jwt_config_ttl_check CHECK ((ttl > '00:00:00'::interval))
);


--
-- Name: manga; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.manga (
    id bigint NOT NULL,
    title extensions.citext NOT NULL,
    sites jsonb DEFAULT '[]'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT private.current_user_id(),
    CONSTRAINT manga_sites_check CHECK (private.is_valid_sites(sites)),
    CONSTRAINT manga_title_check CHECK (((title OPERATOR(extensions.<>) ''::extensions.citext) AND ((title)::text = btrim((title)::text)) AND (length((title)::text) <= 200)))
);


--
-- Name: manga_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.manga ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.manga_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version character varying NOT NULL
);


--
-- Name: user_progress; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_progress (
    user_id uuid DEFAULT private.current_user_id() NOT NULL,
    manga_id bigint NOT NULL,
    status public.manga_status DEFAULT 'plan_to_read'::public.manga_status NOT NULL,
    last_chapter_read numeric DEFAULT 0 NOT NULL,
    worth_reading boolean,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT user_progress_last_chapter_read_check CHECK (((last_chapter_read >= (0)::numeric) AND (last_chapter_read < (100000)::numeric) AND (last_chapter_read = trunc(last_chapter_read, 1))))
);


--
-- Name: account account_email_key; Type: CONSTRAINT; Schema: auth; Owner: -
--

ALTER TABLE ONLY auth.account
    ADD CONSTRAINT account_email_key UNIQUE (email);


--
-- Name: account account_pkey; Type: CONSTRAINT; Schema: auth; Owner: -
--

ALTER TABLE ONLY auth.account
    ADD CONSTRAINT account_pkey PRIMARY KEY (id);


--
-- Name: jwt_config jwt_config_pkey; Type: CONSTRAINT; Schema: auth; Owner: -
--

ALTER TABLE ONLY auth.jwt_config
    ADD CONSTRAINT jwt_config_pkey PRIMARY KEY (singleton);


--
-- Name: manga manga_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.manga
    ADD CONSTRAINT manga_pkey PRIMARY KEY (id);


--
-- Name: manga manga_title_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.manga
    ADD CONSTRAINT manga_title_key UNIQUE (title);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: user_progress user_progress_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_progress
    ADD CONSTRAINT user_progress_pkey PRIMARY KEY (user_id, manga_id);


--
-- Name: user_progress_manga_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_progress_manga_id_idx ON public.user_progress USING btree (manga_id);


--
-- Name: manga manga_set_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER manga_set_updated_at BEFORE UPDATE ON public.manga FOR EACH ROW EXECUTE FUNCTION private.set_updated_at();


--
-- Name: user_progress user_progress_set_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER user_progress_set_updated_at BEFORE UPDATE ON public.user_progress FOR EACH ROW EXECUTE FUNCTION private.set_updated_at();


--
-- Name: manga manga_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.manga
    ADD CONSTRAINT manga_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.account(id) ON DELETE SET NULL;


--
-- Name: user_progress user_progress_manga_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_progress
    ADD CONSTRAINT user_progress_manga_id_fkey FOREIGN KEY (manga_id) REFERENCES public.manga(id) ON DELETE CASCADE;


--
-- Name: user_progress user_progress_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_progress
    ADD CONSTRAINT user_progress_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.account(id) ON DELETE CASCADE;


--
-- Name: manga; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.manga ENABLE ROW LEVEL SECURITY;

--
-- Name: manga manga_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY manga_insert ON public.manga FOR INSERT TO authenticated WITH CHECK ((created_by = private.current_user_id()));


--
-- Name: manga manga_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY manga_read ON public.manga FOR SELECT TO authenticated USING (true);


--
-- Name: manga manga_update_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY manga_update_own ON public.manga FOR UPDATE TO authenticated USING ((created_by = private.current_user_id()));


--
-- Name: user_progress; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.user_progress ENABLE ROW LEVEL SECURITY;

--
-- Name: user_progress user_progress_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY user_progress_own ON public.user_progress TO authenticated USING ((user_id = private.current_user_id())) WITH CHECK ((user_id = private.current_user_id()));


--
-- PostgreSQL database dump complete
--

\unrestrict dbmate


--
-- Dbmate schema migrations
--

INSERT INTO public.schema_migrations (version) VALUES
    ('20261004202731'),
    ('20261004204339');
