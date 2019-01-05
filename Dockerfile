FROM postgres:10.4
MAINTAINER Alessandro Rizzo
RUN apt-get update -qq && \
    apt-get install -y iputils-ping && \
    rm -rf /var/lib/apt/lists/*
ENV PG_MAX_WAL_SENDERS 8
ENV PG_WAL_KEEP_SEGMENTS 8
COPY setup-replication.sh /docker-entrypoint-initdb.d/
COPY docker-entrypoint* /usr/local/bin/
RUN chmod +x /docker-entrypoint-initdb.d/setup-replication.sh /docker-entrypoint.sh \
    && /usr/local/bin/docker-entrypoint-patcher.sh
