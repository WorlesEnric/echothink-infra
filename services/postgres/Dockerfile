FROM postgres:16.13-bookworm

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      postgresql-16-pgvector \
      build-essential \
      git \
      ca-certificates && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

COPY init/ /docker-entrypoint-initdb.d/
COPY conf/postgresql.conf /etc/postgresql/postgresql.conf

CMD ["postgres", "-c", "config_file=/etc/postgresql/postgresql.conf"]
