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
-- Name: private; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA private;


--
-- Name: citext; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS citext WITH SCHEMA public;


--
-- Name: EXTENSION citext; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION citext IS 'data type for case-insensitive character strings';


--
-- Name: pgcrypto; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;


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


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: account; Type: TABLE; Schema: auth; Owner: -
--

CREATE TABLE auth.account (
    id uuid DEFAULT uuidv7() NOT NULL,
    email public.citext NOT NULL,
    password_hash text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT account_email_check CHECK ((email OPERATOR(public.~) '^[^@\s]+@[^@\s]+\.[^@\s]+$'::public.citext))
);


--
-- Name: manga; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.manga (
    id bigint NOT NULL,
    title public.citext NOT NULL,
    sites jsonb DEFAULT '[]'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT manga_sites_check CHECK (private.is_valid_sites(sites)),
    CONSTRAINT manga_title_check CHECK (((title OPERATOR(public.<>) ''::public.citext) AND ((title)::text = btrim((title)::text)) AND (length((title)::text) <= 200)))
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
    user_id uuid NOT NULL,
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
-- PostgreSQL database dump complete
--

\unrestrict dbmate


--
-- Dbmate schema migrations
--

INSERT INTO public.schema_migrations (version) VALUES
    ('20261004202731');
