#!/usr/bin/env bash
set -e

# Backwards compatibility for old variable names (deprecated)
if [ "x$PGUSER"     != "x" ]; then
    POSTGRES_USER=$PGUSER
fi
if [ "x$PGPASSWORD" != "x" ]; then
    POSTGRES_PASSWORD=$PGPASSWORD
fi

# Forwards-compatibility for old variable names (pg_basebackup uses them)
if [ "x$PGPASSWORD" = "x" ]; then
    export PGPASSWORD=$POSTGRES_PASSWORD
fi

# Based on official postgres package's entrypoint script (https://hub.docker.com/_/postgres/)
# Modified to be able to set up a slave. The docker-entrypoint-initdb.d hook provided is inadequate.

# usage: file_env VAR [DEFAULT]
#    ie: file_env 'XYZ_DB_PASSWORD' 'example'
# (will allow for "$XYZ_DB_PASSWORD_FILE" to fill in the value of
#  "$XYZ_DB_PASSWORD" from a file, especially for Docker's secrets feature)
file_env() {
	local var="$1"
	local fileVar="${var}_FILE"
	local def="${2:-}"
	if [ "${!var:-}" ] && [ "${!fileVar:-}" ]; then
		echo >&2 "error: both $var and $fileVar are set (but are exclusive)"
		exit 1
	fi
	local val="$def"
	if [ "${!var:-}" ]; then
		val="${!var}"
	elif [ "${!fileVar:-}" ]; then
		val="$(< "${!fileVar}")"
	fi
	export "$var"="$val"
	unset "$fileVar"
}

if [ "${1:0:1}" = '-' ]; then
	set -- postgres "$@"
fi

# allow the container to be started with `--user`
if [ "$1" = 'postgres' ] && [ "$(id -u)" = '0' ]; then
	mkdir -p "$PGDATA"
	chown -R postgres "$PGDATA"
	chmod 700 "$PGDATA"

	mkdir -p /var/run/postgresql
	chown -R postgres /var/run/postgresql
	chmod 775 /var/run/postgresql

	# Create the transaction log directory before initdb is run (below) so the directory is owned by the correct user
	if [ "$POSTGRES_INITDB_WALDIR" ]; then
		mkdir -p "$POSTGRES_INITDB_WALDIR"
		chown -R postgres "$POSTGRES_INITDB_WALDIR"
		chmod 700 "$POSTGRES_INITDB_WALDIR"
	fi

	exec gosu postgres "$BASH_SOURCE" "$@"
fi

if [ "$1" = 'postgres' ]; then
	mkdir -p "$PGDATA"
	chown -R "$(id -u)" "$PGDATA" 2>/dev/null || :
	chmod 700 "$PGDATA" 2>/dev/null || :

	# look specifically for PG_VERSION, as it is expected in the DB dir
	if [ ! -s "$PGDATA/PG_VERSION" ]; then
		file_env 'POSTGRES_INITDB_ARGS'
		if [ "$POSTGRES_INITDB_WALDIR" ]; then
			export POSTGRES_INITDB_ARGS="$POSTGRES_INITDB_ARGS --waldir $POSTGRES_INITDB_WALDIR"
		fi
      file_env 'REPLICATE_FROM'
      if [ "x$REPLICATE_FROM" == "x" ]; then
		eval "initdb --username=postgres $POSTGRES_INITDB_ARGS"
	  else
        until ping -c 1 -W 1 ${REPLICATE_FROM}
        do
            echo "Waiting for master to ping..."
            sleep 1s
        done
        until gosu postgres pg_basebackup -h ${REPLICATE_FROM} -D ${PGDATA} -U ${POSTGRES_USER} -vP -w
        do
            echo "Waiting for master to connect..."
            sleep 1s
        done
      fi

		# check password first so we can output the warning before postgres
		# messes it up
		file_env 'POSTGRES_PASSWORD'
		if [ "$POSTGRES_PASSWORD" ]; then
			pass="PASSWORD '$POSTGRES_PASSWORD'"
			authMethod=md5
		else
			# The - option suppresses leading tabs but *not* spaces. :)
			cat >&2 <<-'EOWARN'
				****************************************************
				WARNING: No password has been set for the database.
				         This will allow anyone with access to the
				         Postgres port to access your database. In
				         Docker's default configuration, this is
				         effectively any other container on the same
				         system.

				         Use "-e POSTGRES_PASSWORD=password" to set
				         it in "docker run".
				****************************************************
			EOWARN

			pass=
			authMethod=trust
		fi

		if [ "x$REPLICATE_FROM" == "x" ]; then

		{
			echo
			echo "host replication all all $authMethod"
			echo
			echo "host all all all $authMethod"
		} >> "$PGDATA/pg_hba.conf"

		# internal start of server in order to allow set-up using psql-client
		# does not listen on external TCP/IP and waits until start finishes
		PGUSER="${PGUSER:-postgres}" \
		pg_ctl -D "$PGDATA" \
			-o "-c listen_addresses='localhost'" \
			-w start

		file_env 'POSTGRES_USER' 'postgres'
		file_env 'POSTGRES_DB' "$POSTGRES_USER"

		psql=( psql -v ON_ERROR_STOP=1 )

		if [ "$POSTGRES_DB" != 'postgres' ]; then
			"${psql[@]}" --username postgres <<-EOSQL
				CREATE DATABASE "$POSTGRES_DB" ;
			EOSQL
			echo
		fi

		if [ "$POSTGRES_USER" = 'postgres' ]; then
			op='ALTER'
		else
			op='CREATE'
		fi
		"${psql[@]}" --username postgres <<-EOSQL
			$op USER "$POSTGRES_USER" WITH SUPERUSER $pass ;
		EOSQL
		echo

        fi

		psql+=( --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" )

		echo
		for f in /docker-entrypoint-initdb.d/*; do
			case "$f" in
				*.sh)     echo "$0: running $f"; . "$f" ;;
				*.sql)    echo "$0: running $f"; "${psql[@]}" -f "$f"; echo ;;
				*.sql.gz) echo "$0: running $f"; gunzip -c "$f" | "${psql[@]}"; echo ;;
				*)        echo "$0: ignoring $f" ;;
			esac
			echo
		done

	  if [ "x$REPLICATE_FROM" == "x" ]; then
		PGUSER="${PGUSER:-postgres}" \
		pg_ctl -D "$PGDATA" -m fast -w stop
	  fi

		echo
		echo 'PostgreSQL init process complete; ready for start up.'
		echo
	fi
fi

exec "$@"