#!/bin/bash
set -e

mkdir -p "$PGDATA"
chmod 700 "$PGDATA"
chown -R postgres "$PGDATA"

# look specifically for PG_VERSION, as it is expected in the DB dir
if [ ! -s "$PGDATA/PG_VERSION" ]; then
	initdb

	if [ "$POSTGRES_PASSWORD" ]; then
		pass="PASSWORD '$POSTGRES_PASSWORD'"
		authMethod=md5
	else
		pass=
		authMethod=trust
	fi

	{ echo; echo "host all all 0.0.0.0/0 $authMethod"; } >> "$PGDATA/pg_hba.conf"
	{ echo; echo "host replication all 0.0.0.0/0 $authMethod"; } >> "$PGDATA/pg_hba.conf"

	############################################################################

	# internal start of server in order to allow set-up using psql-client
	# does not listen on TCP/IP and waits until start finishes
	pg_ctl -D "$PGDATA" \
		-o "-c listen_addresses=''" \
		-w start

	: ${POSTGRES_USER:=postgres}
	: ${POSTGRES_DB:=$POSTGRES_USER}
	export POSTGRES_USER POSTGRES_DB

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

	############################################################################

	RAFT_PEERS='1:node1:6666, 2:node2:6666, 3:node3:6666'

	cat <<-EOF >> $PGDATA/postgresql.conf
		listen_addresses='*'
		max_prepared_transactions = 100
		synchronous_commit = off
		wal_level = logical
		max_worker_processes = 15
		max_replication_slots = 10
		max_wal_senders = 10
		shared_preload_libraries = 'raftable'
		raftable.id = $NODE_ID
		raftable.peers = '$RAFT_PEERS'
	EOF

	tail -n 20 $PGDATA/postgresql.conf

	pg_ctl -D "$PGDATA" -m fast -w stop

	echo
	echo 'PostgreSQL init process complete; ready for start up.'
	echo
fi

exec "$@"

