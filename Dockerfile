FROM postgres:12.4
MAINTAINER Alessandro Rizzo
ENV PG_MAX_WAL_SENDERS 8
ENV PG_WAL_KEEP_SEGMENTS 8
COPY setup-replication.sh /docker-entrypoint-initdb.d/
COPY docker-entrypoint* /usr/local/bin/
RUN chmod +x /docker-entrypoint-initdb.d/setup-replication.sh /docker-entrypoint.sh \
    && /usr/local/bin/docker-entrypoint-patcher.sh
