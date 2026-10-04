FROM postgres:18.6-trixie

ARG PG_GRAPHQL_VERSION=1.6.2
ARG TARGETARCH

ADD https://github.com/supabase/pg_graphql/releases/download/v${PG_GRAPHQL_VERSION}/pg_graphql-v${PG_GRAPHQL_VERSION}-pg18-${TARGETARCH}-linux-gnu.deb /tmp/pg_graphql.deb

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      postgresql-18-pgvector \
      postgresql-18-cron \
      postgresql-18-pgtap \
      libtap-parser-sourcehandler-pgtap-perl \
      /tmp/pg_graphql.deb \
 && rm -rf /var/lib/apt/lists/* /tmp/pg_graphql.deb
