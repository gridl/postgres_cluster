package Cluster;

use strict;
use warnings;

use PostgresNode;
use TestLib;
use Test::More;
use Cwd;

my $max_port = 5431;
sub allocate_ports
{
	my @allocated_now = ();
	my ($host, $ports_to_alloc) = @_;
	my $port = $max_port + 1;

	while ($ports_to_alloc > 0)
	{
		diag("checking for port $port\n");
		if (!TestLib::run_log(['pg_isready', '-h', $host, '-p', $port]))
		{
			$max_port = $port;
			push(@allocated_now, $port);
			$ports_to_alloc--;
		}
		$port++;
	}

	return @allocated_now;
}

sub new
{
	my ($class, $nodenum) = @_;

	my $nodes = [];

	foreach my $i (1..$nodenum)
	{
		my $host = "127.0.0.1";
		my ($pgport, $raftport) = allocate_ports($host, 2);
		my $node = new PostgresNode("node$i", $host, $pgport);
		$node->{id} = $i;
		$node->{raftport} = $raftport;
		push(@$nodes, $node);
	}

	my $self = {
		nodenum => $nodenum,
		nodes => $nodes,
	};

	bless $self, $class;
	return $self;
}

sub init
{
	my ($self) = @_;
	my $nodes = $self->{nodes};

	foreach my $node (@$nodes)
	{
		$node->init(hba_permit_replication => 0);
	}
}

sub detach 
{
	my ($self) = @_;
	my $nodes = $self->{nodes};

	foreach my $node (@$nodes)
	{
		delete $node->{_pid};
	}
}

sub configure
{
	my ($self) = @_;
	my $nodes = $self->{nodes};

	my $connstr = join(',', map { "${ \$_->connstr('postgres') }" } @$nodes);
	my $raftpeers = join(',', map { join(':', $_->{id}, $_->host, $_->{raftport}) } @$nodes);

	foreach my $node (@$nodes)
	{
		my $id = $node->{id};
		my $host = $node->host;
		my $pgport = $node->port;
		my $raftport = $node->{raftport};

		$node->append_conf("postgresql.conf", qq(
			listen_addresses = '$host'
			unix_socket_directories = ''
			port = $pgport
			max_prepared_transactions = 200
			max_connections = 200
			max_worker_processes = 100
			wal_level = logical
			fsync = off	
			max_wal_senders = 10
			wal_sender_timeout = 0
			max_replication_slots = 10
			shared_preload_libraries = 'raftable,multimaster'
			multimaster.workers = 10
			multimaster.queue_size = 10485760 # 10mb
			multimaster.node_id = $id
			multimaster.conn_strings = '$connstr'
			multimaster.use_raftable = true
			multimaster.ignore_tables_without_pk = true
			multimaster.twopc_min_timeout = 60000
			raftable.id = $id
			raftable.peers = '$raftpeers'
		));

		$node->append_conf("pg_hba.conf", qq(
			local replication all trust
			host replication all 127.0.0.1/32 trust
			host replication all ::1/128 trust
		));
	}
}

sub start
{
	my ($self) = @_;
	my $nodes = $self->{nodes};

	foreach my $node (@$nodes)
	{
		$node->start();
	}
}

sub stop
{
	my ($self) = @_;
	my $nodes = $self->{nodes};

	foreach my $node (@$nodes)
	{
		$node->stop();
	}
}

sub psql
{
	my ($self, $index, @args) = @_;
	my $node = $self->{nodes}->[$index];
	return $node->psql(@args);
}

1;
