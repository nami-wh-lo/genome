package Genome::Disk::Volume;

use strict;
use warnings;

use Genome;
use Carp;

use Data::Dumper;
use Filesys::Df qw();
use List::Util qw(max);
use Scope::Guard;

class Genome::Disk::Volume {
    table_name => 'disk.volume',
    id_generator => '-uuid',
    id_by => [
        id => { is => 'Text', len => 32 },
    ],
    has => [
        hostname => { is => 'Text', default => 'unknown' },
        physical_path => { is => 'Text' },
        mount_path => { is => 'Text' },
        disk_status => {
            is => 'Text',
            valid_values => ['inactive', 'active'],
        },
        can_allocate => {
            is => 'Boolean', default_value => 1,
        },
        total_kb => { is => 'Number' },
        total_gb => {
            calculate_from => 'total_kb',
            calculate => q{ return int($total_kb / (2**20)) },
        },
        soft_limit_kb => {
            calculate_from => ['total_kb', 'maximum_reserve_size'],
            calculate => q{ $self->_compute_lower_limit($total_kb, 0.95, $maximum_reserve_size); },
        },
        soft_limit_gb => {
            calculate_from => 'soft_limit_kb',
            calculate => q{ return int($soft_limit_kb / (2**20)) },
        },
        hard_limit_kb => {
            calculate_from => ['total_kb', 'maximum_reserve_size'],
            calculate => q{ $self->_compute_lower_limit($total_kb, 0.98, int(0.5 * $maximum_reserve_size)); },
        },
        hard_limit_gb => {
            calculate_from => 'hard_limit_kb',
            calculate => q{ return int($hard_limit_kb / (2**20)) },
        },
        unallocated_kb => {
            calculate_from => ['total_kb', 'allocated_kb'],
            calculate => q{ return $total_kb - $allocated_kb },
        },
        cached_unallocated_kb => {
            is => 'Number',
            default_value => 0,
            column_name => 'unallocated_kb',
        },
        unallocated_gb => {
            calculate_from => 'unallocated_kb',
            calculate => q{ return int($unallocated_kb / (2**20)) },
        },
        allocated_kb => {
            is_calculated => 1,
        },
        percent_allocated => {
            calculate_from => ['total_kb', 'allocated_kb'],
            calculate => q{ return sprintf("%.2f", ( $allocated_kb / $total_kb ) * 100); },
        },
        used_kb => {
            calculate_from => ['mount_path'],
            calculate => q{ $self = shift; return $self->df->{used} },
        },
        percent_used => {
            calculate_from => ['total_kb', 'used_kb'],
            calculate => q{ return sprintf("%.2f", ( $used_kb / $total_kb ) * 100); },
        },
        maximum_reserve_size => {
            is => 'Number',
            is_constant => 1,
            is_classwide => 1,
            column_name => '',
            value => 1_073_741_824,
        },
    ],

    has_many_optional => [
        disk_group_names => {
            via => 'groups',
            to => 'name',
        },
        groups => {
            is => 'Genome::Disk::Group',
            via => 'assignments',
            to =>  'group',
        },
        assignments => {
            is => 'Genome::Disk::Assignment',
            reverse_id_by => 'volume',
        },
        allocations => {
            is => 'Genome::Disk::Allocation',
            calculate_from => 'mount_path',
            calculate => q| return Genome::Disk::Allocation->get(mount_path => $mount_path); |,
        },
    ],
    data_source => 'Genome::DataSource::GMSchema',
    doc => 'Represents a particular disk volume (eg, sata483)',
};

sub __display_name__ {
    my $self = shift;
    return $self->mount_path;
}

sub _compute_lower_limit {
    my $class = shift;
    my ($total_kb, $fraction, $maximum_reserve_size) = @_;
    my $fractional_limit = int($total_kb * $fraction);
    my $subtractive_limit = $total_kb - $maximum_reserve_size;
    return max($fractional_limit, $subtractive_limit);
}

sub allocated_kb {
    my $self = shift;

    # This used to use a copy of UR::Object::Set's server-side aggregate
    # logic to ensure no client-side calculation was done (for performance).
    # Now we're going to just let the set do the sum and monitor the
    # performance (in allocated_kb calculated property). If performance
    # is bad we can revert.

    my $set = Genome::Disk::Allocation->define_set(mount_path => $self->mount_path);
    my $field = 'kilobytes_requested';

    $set->__invalidate_cache__("sum($field)");

    # We only want to time the sum aggregate, not including any time to connect to the DB
    Genome::Disk::Allocation->__meta__->data_source->get_default_handle();
    my $allocated_kb = ($set->sum($field) or 0);
    my $allocation_count = $set->count();

    if (wantarray) {
        return $allocated_kb, $allocation_count;
    } else {
        return $allocated_kb;
    }
}

sub soft_unallocated_kb {
    my $self = shift;
    return $self->soft_limit_kb - $self->allocated_kb;
}

sub hard_unallocated_kb {
    my $self = shift;
    return $self->hard_limit_kb - $self->allocated_kb;
}

sub unused_kb {
    my $self = shift;
    return $self->total_kb - $self->used_kb;
}

sub soft_unused_kb {
    my $self = shift;
    return $self->soft_limit_kb - $self->used_kb;
}

sub hard_unused_kb {
    my $self = shift;
    return $self->hard_limit_kb - $self->used_kb;
}

our @dummy_volumes;
sub create_dummy_volume {
    my ($class, %params) = @_;
    my $mount_path = $params{mount_path};
    my $volume;

    my $original_use_dummy_ids = UR::DataSource->use_dummy_autogenerated_ids;
    my $guard = Scope::Guard->new(sub { UR::DataSource->use_dummy_autogenerated_ids($original_use_dummy_ids) });
    UR::DataSource->use_dummy_autogenerated_ids(1);

    if (!$mount_path || ($mount_path && $mount_path !~ /^\/tmp\//)) {
        $params{mount_path} = File::Temp::tempdir( 'tempXXXXX', TMPDIR => 1, CLEANUP => 1 );
        $volume = Genome::Disk::Volume->__define__(
            mount_path => $params{mount_path},
            total_kb => Filesys::Df::df($params{mount_path})->{blocks},,
            can_allocate => 1,
            disk_status => 'active',
            hostname => 'localhost',
            physical_path => '/tmp',
        );
        push @dummy_volumes, $volume;
        my $disk_group = Genome::Disk::Group->get(disk_group_name => $params{disk_group_name});
        Genome::Disk::Assignment->__define__(
            volume => $volume,
            group => $disk_group,
        );
    }
    else {
        $volume = Genome::Disk::Volume->get_active_volume(mount_path => $mount_path);
    }

    return $volume;
}

sub archive_mount_path {
    my $self = shift;

    my $mount = $self->mount_path;
    $mount =~ s!/Active(/|$)!/Archive$1!;
    return $mount;
}

sub active_mount_path {
    my $self = shift;

    return $self->mount_path;
}

sub is_mounted {
    my $self = shift;

    if ($ENV{UR_DBI_NO_COMMIT}) {
        return 1;
    }

    if (-l $self->mount_path) {
        return 1; #trust that symlinks are mounted
    }

    # We can't use Filesys::Df::df because it doesn't report the mount path only the stats.
    my $mount_path = $self->mount_path;
    my $path_to_df = $self->is_remote_volume ? $self->physical_path : $mount_path;
    my @df_output = qx(df -P $path_to_df 2> /dev/null);
    if ($! && $! !~ /No such file or directory/) {
        die $self->error_message(sprintf('Failed to `df %s` to check if volume is mounted: %s', $mount_path, $!));
    }

    my ($df_output) = grep { /\s$path_to_df$/ } @df_output;
    return ($df_output ? 1 : 0);
}

sub archive_is_mounted {
    my $self = shift;

    if ($ENV{UR_DBI_NO_COMMIT}) { 
        return 1;
    }

    return -d $self->archive_mount_path;
}

sub is_remote_volume {
    my $self = shift;

    return $self->hostname =~ /\./;
}

sub df {
    my $self = shift;

    unless ($self->is_mounted) {
        die $self->error_message(sprintf('Volume %s is not mounted!', $self->mount_path));
    }

    if ($self->is_remote_volume) {
        #for now, take our allocation records on faith
        return { used => scalar($self->allocated_kb), blocks => $self->total_kb };
    } else {
        return Filesys::Df::df($self->mount_path);
    }
}

sub sync_total_kb {
    my $self = shift;

    my $total_kb = $self->df->{blocks};
    if ($self->total_kb != $total_kb) {
        $self->total_kb($total_kb);
    }

    return $total_kb;
}

sub sync_unallocated_kb {
    my $self = shift;

    my $unallocated_kb = $self->unallocated_kb;
    if ($self->cached_unallocated_kb != $unallocated_kb) {
        $self->cached_unallocated_kb($unallocated_kb);
    }

    return $unallocated_kb;
}

sub is_allocated_over_soft_limit {
    my $self = shift;
    return ($self->allocated_kb > $self->soft_limit_kb);
}

sub is_used_over_soft_limit {
    my $self = shift;
    return ($self->used_kb > $self->soft_limit_kb);
}

sub is_over_soft_limit {
    my $self = shift;
    return ($self->is_allocated_over_soft_limit || $self->is_used_over_soft_limit);
}

sub is_allocated_over_hard_limit {
    my $self = shift;
    return ($self->allocated_kb > $self->hard_limit_kb);
}

sub is_used_over_hard_limit {
    my $self = shift;
    return ($self->used_kb > $self->hard_limit_kb);
}

sub is_over_hard_limit {
    my $self = shift;
    return ($self->is_allocated_over_hard_limit || $self->is_used_over_hard_limit);
}

sub get_active_volume {
    my $class = shift;
    my %defaults = (disk_status => 'active', can_allocate => 1);
    my %params = (%defaults, @_);
    return $class->get(%params);
}

sub has_space {
    my ($self, $skip_disk_query, $kilobytes_requested) = @_;

    my $kb = $self->allocated_kb;
    unless($skip_disk_query) {
        $kb = max($self->used_kb, $kb);
    }
    return ($kb + $kilobytes_requested <= $self->soft_limit_kb);
}

sub is_near_soft_limit {
    my $self = shift;

    my ($total_allocated_kb, $allocation_count) = $self->allocated_kb;
    my $avg_allocated_kb = $allocation_count
                         ? ($total_allocated_kb / $allocation_count)
                         : 0;

    my $kb = max($self->used_kb, $total_allocated_kb);

    my $threshold = 3 * $avg_allocated_kb;
    return (($self->soft_limit_kb - $kb) < $threshold );
}

sub _resolve_param_value_from_text_by_name_or_id {
    my $class = shift;
    my $param_arg = shift;

    #First try default behaviour of looking up by name or id
    my @results = Command::V2->_resolve_param_value_from_text_by_name_or_id($class, $param_arg);

    #If that didn't work, see if we were given the path for the volume
    if(!@results) {
        @results = $class->get(mount_path => $param_arg);
    }

    return @results;
}
1;
