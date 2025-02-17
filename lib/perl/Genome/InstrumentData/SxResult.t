#!/usr/bin/env genome-perl

use strict;
use warnings;

BEGIN {
    $ENV{UR_DBI_NO_COMMIT} = 1;
    $ENV{UR_USE_DUMMY_AUTOGENERATED_IDS} = 1;
    $ENV{UR_COMMAND_DUMP_STATUS_MESSAGES} = 1;
};

require File::Compare;
use Test::More;

use above 'Genome';
use Genome::Test::Factory::SoftwareResult::User;

use_ok('Genome::InstrumentData::SxResult');
use_ok('Genome::InstrumentData::InstrumentDataTestObjGenerator');

my $data_dir = Genome::Config::get('test_inputs') . '/Genome-InstrumentData-SxResult';

my ($instrument_data) = Genome::InstrumentData::InstrumentDataTestObjGenerator::create_solexa_instrument_data($data_dir.'/inst_data/-6666/archive.bam');
my $read_processor = '';
my $output_file_count = 2;
my $output_file_type = 'sanger';

my %sx_result_params = (
    instrument_data_id => $instrument_data->id,
    read_processor => $read_processor,
    output_file_count => $output_file_count,
    output_file_type => $output_file_type,
    test_name => (Genome::Config::get('software_result_test_name') || undef),
    users => Genome::Test::Factory::SoftwareResult::User->setup_user_hash,
);

my $sx_result = Genome::InstrumentData::SxResult->get_or_create(%sx_result_params);
isa_ok($sx_result, 'Genome::InstrumentData::SxResult', 'successful run');
my $get_sx_result = Genome::InstrumentData::SxResult->get_with_lock(%sx_result_params);
is_deeply($get_sx_result, $sx_result, 'Re-got sx result');

my @read_processor_output_files = $sx_result->read_processor_output_files;
ok(@read_processor_output_files, 'produced read processor output files');
is_deeply(\@read_processor_output_files, [map { $instrument_data->id.'.'.$_.'.fastq' } (qw/ 1 2 /)], 'correctly names read processor output files');

# metrics
is_deeply([$sx_result->metric_names], [qw/ input_bases input_count output_bases output_count /], 'metric names');
is($sx_result->read_processor_input_metric_file_base_name, $instrument_data->id.'.input_metrics', 'input metric file base name');
is(
    $sx_result->temp_staging_input_metric_file,
    $sx_result->temp_staging_directory.'/'.$sx_result->read_processor_input_metric_file_base_name,
    'temp staging input metric file',
);
ok(-s $sx_result->temp_staging_input_metric_file, 'temp statging input metric file has size');
is(
    $sx_result->read_processor_input_metric_file,
    $sx_result->output_dir.'/'.$sx_result->read_processor_input_metric_file_base_name,
    'read processor input metric file',
);
ok(-s $sx_result->read_processor_input_metric_file, 'input metric file has size');

is($sx_result->read_processor_output_metric_file_base_name, $instrument_data->id.'.output_metrics', 'output metric file base name');
is(
    $sx_result->temp_staging_output_metric_file,
    $sx_result->temp_staging_directory.'/'.$sx_result->read_processor_output_metric_file_base_name,
    'temp statging output metric file',
);
ok(-s $sx_result->temp_staging_output_metric_file, 'temp staging output metric file has size');
is(
    $sx_result->read_processor_output_metric_file,
    $sx_result->output_dir.'/'.$sx_result->read_processor_output_metric_file_base_name,
    'output metric file',
);
ok(-s $sx_result->read_processor_output_metric_file, 'output metric file');

is($sx_result->input_bases, 8999908, 'metrics input bases');
is($sx_result->input_count, 89108, 'metrics input count');
is($sx_result->output_bases, 8999908, 'metrics output bases');
is($sx_result->output_count, 89108, 'metrics output count');
#/metrics

$sx_result_params{output_file_count} = 1;
my $sx_result3 = Genome::InstrumentData::SxResult->get_with_lock(%sx_result_params);
ok(!$sx_result3, 'request with different (yet unrun) parameters returns no result');

my $sx_result4 = Genome::InstrumentData::SxResult->get_or_create(%sx_result_params);
isa_ok($sx_result4, 'Genome::InstrumentData::SxResult', 'successful run');
isnt($sx_result4, $sx_result, 'produced different result');

# use output file config [should be same output as above]
my %sx_result_params_with_config = (
    instrument_data_id => $instrument_data->id,
    read_processor => $read_processor,
    output_file_config => [ 
        'basename='.$instrument_data->id.'.1.fastq:type=sanger:name=fwd', 'basename='.$instrument_data->id.'.2.fastq:type=sanger:name=rev',
    ],
    test_name => (Genome::Config::get('software_result_test_name') || undef),
    users => Genome::Test::Factory::SoftwareResult::User->setup_user_hash,
);

my $sx_result_with_config = Genome::InstrumentData::SxResult->get_or_create(%sx_result_params_with_config);
isa_ok($sx_result_with_config, 'Genome::InstrumentData::SxResult', 'successful run w/ config');
my $get_sx_result_with_config = Genome::InstrumentData::SxResult->get_with_lock(%sx_result_params_with_config);
is_deeply($get_sx_result_with_config, $sx_result_with_config, 'Re-got sx result w/ config');
isnt($get_sx_result_with_config->output_dir, $sx_result->output_dir, 'Output dirs do not match b/c we reran SX');
my @output_files = $sx_result->read_processor_output_files;
ok(@output_files, 'produced read processor output files w/ config');
for ( my $i = 0; $i < @read_processor_output_files; $i++ ) {
    is($output_files[$i], $read_processor_output_files[$i], 'correctly named read processor output files');
    is(
        File::Compare::compare($sx_result_with_config->output_dir.'/'.$output_files[$i], $sx_result->output_dir.'/'.$read_processor_output_files[$i]),
        0,
        "Output file $i matches!",
    );
}

# success - no output files created
$sx_result_params{read_processor} = 'filter by-min-length --length 2000';
my $sx_result_all_reads_filtered = Genome::InstrumentData::SxResult->get_or_create(%sx_result_params);
isa_ok($sx_result_all_reads_filtered, 'Genome::InstrumentData::SxResult', 'get_or_create sx result w/ all reads filtered');
my $get_sx_result_all_reads_filtered = Genome::InstrumentData::SxResult->get_with_lock(%sx_result_params);
is_deeply($get_sx_result_all_reads_filtered, $sx_result_all_reads_filtered, 'Re-get sx result w/ result w/ all reads filtered');
@output_files = $sx_result_all_reads_filtered->read_processor_output_files;
ok(@output_files, 'produced read processor output files w/ config');
ok(!(grep { -e } @output_files), 'output files exist');
ok(!(grep { -s } @output_files), 'output files do not have any size');
is($sx_result_all_reads_filtered->input_bases, 8999908, 'metrics input bases');
is($sx_result_all_reads_filtered->input_count, 89108, 'metrics input count');
is($sx_result_all_reads_filtered->output_bases, 0, 'metrics output bases');
is($sx_result_all_reads_filtered->output_count, 0, 'metrics output count');

# fail - rm output metrics and verify files

# fails [create]
ok( # no config or count
    !Genome::InstrumentData::SxResult->create(
        instrument_data_id => $instrument_data->id,
        read_processor => $read_processor,
    ),
    'Did not create sx result w/ config w/o basename',
);
ok( # no basename in output file config
    !Genome::InstrumentData::SxResult->create(
        instrument_data_id => $instrument_data->id,
        read_processor => $read_processor,
        output_file_config => [ 'type=sanger' ],
    ),
    'Did not create sx result w/ config w/o basename',
);
ok( # invalid basename in output file config
    !Genome::InstrumentData::SxResult->create(
        instrument_data_id => $instrument_data->id,
        read_processor => $read_processor,
        output_file_config => [ 'basename=/carter:type=sanger' ],
    ),
    'Did not create sx result w/ config w/o basename',
);
ok( # invalid basename in output file config
    !Genome::InstrumentData::SxResult->create(
        instrument_data_id => $instrument_data->id,
        read_processor => $read_processor,
        output_file_config => [ 'basename=johnny cash:type=sanger' ],
    ),
    'Did not create sx result w/ config w/o basename',
);
ok( # no type in output file config
    !Genome::InstrumentData::SxResult->create(
        instrument_data_id => $instrument_data->id,
        read_processor => $read_processor,
        output_file_config => [ 'basename=carter' ],
    ),
    'Did not create sx result w/ config w/o basename',
);

# fails [_verify_output_files]
my $input_count = $sx_result->input_count;
$sx_result->input_count(0);
ok(!$sx_result->_verify_output_files, 'failed to verify output files b/c input count is 0');
is($sx_result->error_message, 'Input count is 0! Failed to process any sequences!', 'correct error');
$sx_result->input_count($input_count);

done_testing;
