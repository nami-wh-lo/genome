#!/usr/bin/env genome-perl

# This test is basically a mini build test.

BEGIN { 
    $ENV{UR_DBI_NO_COMMIT} = 1;
    $ENV{UR_USE_DUMMY_AUTOGENERATED_IDS} = 1;
    $ENV{UR_COMMAND_DUMP_STATUS_MESSAGES} = 1;
}

use strict;
use warnings;

use above "Genome";

require File::Compare;
use File::Temp;
use Test::More;

use Genome::Test::Factory::AnalysisProject;

if (Genome::Sys->arch_os ne 'x86_64') {
    plan skip_all => 'requires 64-bit machine';
}

use_ok('Genome::Model::Build::DeNovoAssembly::Allpaths') or die;

UR::DataSource->next_dummy_autogenerated_id;
do {
    $UR::DataSource::last_dummy_autogenerated_id = int($UR::DataSource::last_dummy_autogenerated_id / 10);
} until length($UR::DataSource::last_dummy_autogenerated_id) < 9;
diag('Dummy ID: '.$UR::DataSource::last_dummy_autogenerated_id);
cmp_ok(length($UR::DataSource::last_dummy_autogenerated_id), '<',  9, 'dummy id is shorter than 9 chars');

# dir
my $base_dir = Genome::Config::get('test_inputs') . '/Genome-Model/DeNovoAssembly';
my $example_dir = $base_dir.'/allpaths_v3';
ok(-d $example_dir, 'example dir') or die;

my $tmpdir_template = "/DeNovoAssembly-Allpaths.t-XXXXXXXX";
my $tmpdir = File::Temp::tempdir($tmpdir_template, CLEANUP => 1, TMPDIR => 1);
ok(-d $tmpdir, 'temp dir: '.$tmpdir);

#taxon
my $taxon = Genome::Taxon->__define__(
    id => -3456,
    name => 'TEST-taxon',
    estimated_genome_size => 200000,
);
ok($taxon, 'define taxon');

my $source = Genome::Individual->__define__(
    name => 'TEST-ind',
    taxon => $taxon,
);
ok($source, 'define source');

# sample
my $sample = Genome::Sample->__define__(
    id => -1234,
    name => 'TEST-000',
    source => $source,
);
ok($sample, 'define sample') or die;

# libraries/inst data
# fragment
my $frag_library = Genome::Library->__define__(
    id => -1235,
    name => $sample->name.'-testlibs1',
    sample_id => $sample->id,
    library_insert_size => 180,
);
ok($frag_library, 'define frag library') or die;
my $frag_inst_data = Genome::InstrumentData::Solexa->__define__(
    id => -6666,
    original_est_fragment_size => 180,
    original_est_fragment_size_min => 153,
    original_est_fragment_size_max => 207,
    sequencing_platform => 'solexa',
    read_length => 101,
    subset_name => '1-AAAAA',
    index_sequence => 'AAAAA',
    run_name => 'XXXXXX/1-AAAAA',
    run_type => 'Paired',
    flow_cell_id => 'XXXXXX',
    lane => 1,
    library => $frag_library,
    bam_path => $base_dir.'/inst_data/-6666/archive.bam',
    clusters => 44554,
    fwd_clusters => 44554,
    rev_clusters => 44554,
    analysis_software_version => 'not_old_iilumina',
    read_orientation => 'forward_reverse',
);
ok($frag_inst_data, 'define frag inst data');
ok($frag_inst_data->is_paired_end, 'inst data is paired');
ok(-s $frag_inst_data->bam_path, 'inst data bam path');

# jump
my $jump_library = Genome::Library->__define__(
    id => -1236,
    name => $sample->name.'-testlibs2',
    sample_id => $sample->id,
    library_insert_size => 180,
);
ok($jump_library, 'define jump library') or die;
my $jump_inst_data = Genome::InstrumentData::Solexa->__define__(
    id => -5555,
    sequencing_platform => 'solexa',
    read_length => 101,
    subset_name => '1-AAAAA',
    index_sequence => 'AAAAA',
    run_name => 'XXXXXX/1-AAAAA',
    run_type => 'Paired',
    flow_cell_id => 'XXXXXX',
    lane => 1,
    library => $jump_library,
    bam_path => $base_dir.'/inst_data/-6666/archive.bam',
    clusters => 44554,
    fwd_clusters => 44554,
    rev_clusters => 44554,
    analysis_software_version => 'not_old_iilumina',
    original_est_fragment_size => 3000,
    original_est_fragment_size_max => 4000,
    original_est_fragment_size_min => 2000,
    read_orientation => 'reverse_forward',
);
ok($jump_inst_data, 'define jump inst data');
ok($jump_inst_data->is_paired_end, 'inst data is paired');
ok(-s $jump_inst_data->bam_path, 'inst data bam path');

my $pp = Genome::ProcessingProfile::DeNovoAssembly->__define__(
    name => 'De Novo Assembly Allpaths PGA Test',
    assembler_name => 'allpaths de-novo-assemble',
    assembler_version => '41055',
    assembler_params => '-ploidy 1',
    type_name => 'de novo assembly',
    #read_processor => 'trim bwa-style -trim-qual-level 10 | filter by-length -filter-length 35 | rename illumina-to-pcap',
    #post_assemble => 'standard-outputs -min_contig_length 10',
);
ok($pp, 'define pp') or die;

my $model = Genome::Model::DeNovoAssembly->create(
    processing_profile => $pp,
    subject_name => $sample->name,
    subject_type => 'sample_name',
    center_name => 'WUGC',
);

ok($model, 'create allpaths de novo model') or die;
ok($model->add_instrument_data($jump_inst_data), 'add jump inst data to model');

my $anp = Genome::Test::Factory::AnalysisProject->setup_object();
$anp->add_model_bridge(model_id => $model->id);

my $bad_build = Genome::Model::Build::DeNovoAssembly->create(
    model => $model,
    data_directory => $tmpdir,
);

ok($bad_build, 'created build');
my @bad_invalid_tags = $bad_build->validate_for_start;
is(scalar(@bad_invalid_tags), 1, 'build cannot start without frag inst data');
like($bad_invalid_tags[0]->desc, qr/No sloptig library instrument data found/, 'tag indicates proper error');

ok($model->add_instrument_data($frag_inst_data), 'add frag inst data to model');

my $build = Genome::Model::Build::DeNovoAssembly->create(
    model => $model,
    data_directory => $tmpdir,
);

ok($build, 'created build');
my @invalid_tags = $build->validate_for_start;
ok(!@invalid_tags, 'build can start');
my $example_build = Genome::Model::Build->create(
    model => $model,
    data_directory => $example_dir,
);
ok($example_build, 'create example build');

my $workflow = $pp->_resolve_workflow_for_build($build);
$workflow->validate();

my %workflow_inputs = $model->map_workflow_inputs($build);
my %expected_workflow_inputs = (
        build => $build,
        instrument_data => [$jump_inst_data, $frag_inst_data],
    );
is_deeply(\%workflow_inputs, \%expected_workflow_inputs,
    'map_workflow_inputs succeeded');

my $success = $workflow->execute_inline(\%workflow_inputs);
ok($success, 'workflow completed');


my %frag_read_processor_params = $build->read_processor_params_for_instrument_data(
    $frag_inst_data);
my %jump_read_processor_params = $build->read_processor_params_for_instrument_data(
    $jump_inst_data);

my $result_users = Genome::SoftwareResult::User->user_hash_for_build($build);

my $frag_result = Genome::InstrumentData::SxResult->get_with_lock(%frag_read_processor_params, users => $result_users);
my $jump_result = Genome::InstrumentData::SxResult->get_with_lock(%jump_read_processor_params, users => $result_users);

my @frag_read_processor_output_files = $frag_result->read_processor_output_files;
my @jump_read_processor_output_files = $jump_result->read_processor_output_files;

my @all_output_files = map{$build->data_directory.'/'.$_} (
    @frag_read_processor_output_files, @jump_read_processor_output_files);
my @all_example_output_files = map{$example_build->data_directory.'/'.$_} (
    @frag_read_processor_output_files, @jump_read_processor_output_files);

my $fileCount = scalar @all_output_files;
for (my $i=0; $i<$fileCount; $i++) {
    ok(-s $all_output_files[$i], 'output file exists');
    ok(-s $all_example_output_files[$i], 'example output file exists');
    my $output_diff = Genome::Sys->diff_file_vs_file(
        $all_output_files[$i], $all_example_output_files[$i]);
    ok(!$output_diff, 'file contents are the same as expected for '
        . $all_output_files[$i]) or diag('diff:\n'.$output_diff);
}

# check read metrics
my @build_metric_names = sort(map {$_->name} $build->metrics);
my @unique_build_metric_names = sort(List::MoreUtils::uniq(@build_metric_names));

is_deeply(\@build_metric_names, \@unique_build_metric_names,
    'no duplicate metrics');

my $in_libs_file = $build->_allpaths_in_libs_file;
my $in_groups_file = $build->_allpaths_in_group_file;

my $expected_in_libs_file = $example_build->_allpaths_in_libs_file;
my $expected_in_groups_file = $example_build->_allpaths_in_group_file;

ok (-s $in_libs_file, $in_libs_file.' created');
ok (-s $in_groups_file, $in_groups_file.' created');

my $sed_cmd = "sed 's|[:space:]+|\t|g'";
my $in_libs_string = `cat $in_libs_file | $sed_cmd`;
my $expected_in_libs_string = `cat $in_libs_file | $sed_cmd`;
chomp $in_libs_string;
chomp $expected_in_libs_string;
my $in_libs_diff = Genome::Sys->diff_text_vs_text($in_libs_string,
    $expected_in_libs_string);

ok (!$in_libs_diff, 'in_libs.csv content as expected')
    or diag('diff:\n'.$in_libs_diff);
my $in_groups_string = `cat $in_groups_file | $sed_cmd | cut -f 1,2`;
$sed_cmd = "sed 's#TMPDIR#".$build->data_directory."#g'".
            " | sed 's#[:space:]+#\t#g' | cut -f 1,2";
my $expected_in_groups_string = `cat $expected_in_groups_file | $sed_cmd`;
chomp $in_groups_string;
chomp $expected_in_groups_string;
my $in_groups_diff = Genome::Sys->diff_text_vs_text($in_groups_string,
    $expected_in_groups_string);
ok(!$in_groups_diff, 'in_groups.csv content as expected')
    or diag('diff: '.$in_groups_diff);

my %expected_metrics = (
    reads_attempted => 178216,
    reads_processed => 178216,
    reads_processed_success => "1.000",
);

foreach my $metric_name (keys %expected_metrics) {
    is($build->get_metric($metric_name), $expected_metrics{$metric_name},
        "metric ok: '$metric_name'" );
}

#print $build->data_directory."\n";<STDIN>;
done_testing();
