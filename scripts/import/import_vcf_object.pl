#!/usr/bin/perl

=head1 LICENSE

  Copyright (c) 1999-2010 The European Bioinformatics Institute and
  Genome Research Limited.  All rights reserved.

  This software is distributed under a modified Apache license.
  For license details, please see

    http://www.ensembl.org/info/about/code_licence.html

=head1 CONTACT

  Please email comments or questions to the public Ensembl
  developers list at <ensembl-dev@ebi.ac.uk>.

  Questions may also be sent to the Ensembl help desk at
  <helpdesk@ensembl.org>.

=cut

=head1 NAME
import_vcf.pl - imports variations from a VCF file into an Ensembl variation DB

by Will McLaren (wm2@ebi.ac.uk)
=cut

use strict;
use Bio::EnsEMBL::Registry;
use Bio::EnsEMBL::Utils::Sequence qw(reverse_comp);
use Bio::EnsEMBL::Variation::Utils::VEP qw(parse_line get_all_consequences progress end_progress);
use Bio::EnsEMBL::Variation::Utils::Sequence qw(SO_variation_class);

# object types need to imported explicitly to use new_fast
use Bio::EnsEMBL::Variation::Variation;
use Bio::EnsEMBL::Variation::IndividualGenotype;

use Getopt::Long;
use FileHandle;
use Socket;
use IO::Handle;
use Data::Dumper;
use Time::HiRes qw(gettimeofday tv_interval);
use ImportUtils qw(load);
use FindBin qw( $Bin );

use constant DISTANCE => 100_000;
use constant MAX_SHORT => 2**16 -1;

my %Printable = ( "\\"=>'\\', "\r"=>'r', "\n"=>'n', "\t"=>'t', "\""=>'"' );

$| = 1;

my $config = configure();

# open cross-process pipes for fork comms
socketpair(CHILD, PARENT, AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die "ERROR: Failed to open socketpair: $!";
CHILD->autoflush(1);
PARENT->autoflush(1);


# check if we are forking
if(
   defined($config->{input_file}) &&
   -e $config->{input_file} &&
   $config->{input_file} =~ /\.gz$/ &&
   -e $config->{input_file}.'.tbi' &&
   defined($config->{fork})
) {
	run_forks($config);
}
else {
	main($config);
}

sub configure {
	
	# COMMAND LINE OPTIONS
	######################
	
	# get command-line options
	my $config = {};
	my $args = scalar @ARGV;
	
	GetOptions(
		$config,
		
		'help|h',
		'input_file|i=s',
		'tmpdir=s',
		'tmpfile=s',
		'config=s',
		
		'species=s',
		'registry|r=s',
		'host=s',
		'database|db=s',
		'user=s',
		'password=s',
		'port=i',
		
		'sql=s',
		'coord_system=s',
		
		'source=s',
		'source_desc=s',
		'population|pop=s',
		'pedigree=s',
		'panel=s',
		'gmaf=s',
		
		'flank=s',
		'gp',
		'ind_prefix=s',
		'pop_prefix=s',
		'var_prefix=s',
		
		'disable_keys',
		'tables=s',
		'skip_tables=s',
		
		'merge_vfs',
		'only_existing',
		
		'create_name',
		'chrom_regexp=s',
		'force_no_var',
		
		'fork=i',
		'test=i',
		'backup',
		'move',
		
	# die if we can't parse arguments - better to get user to sort out their command line
	# than potentially do the wrong thing
	) or die "ERROR: Failed to parse command line arguments - check the documentation!\n";
	
	
	# print usage message if requested or no args supplied
	if(defined($config->{help}) || !$args) {
		&usage;
		exit(0);
	}
	
	# read config from file?
    read_config_from_file($config, $config->{config}) if defined $config->{config};
	
	# sanity checks
	die("ERROR: Cannot run in test mode using forks\n") if defined($config->{fork}) and defined($config->{test});
	
	# set defaults
	$config->{species}      ||= "human";
	$config->{flank}        ||= 200;
	$config->{port}         ||= 3306;
	$config->{format}         = 'vcf';
	$config->{ind_prefix}   ||= '';
	$config->{pop_prefix}   ||= '';
	$config->{coord_system} ||= 'chromosome';
	
	# set default list of tables to write to
	my $tables = {
		'variation'                       => 1,
		'variation_feature'               => 1,
		'variation_synonym'               => 1,
		'flanking_sequence'               => 1,
		'allele'                          => 1,
		'population_genotype'             => 1,
		'compressed_genotype_var'         => 1,
		'individual_genotype_multiple_bp' => 0,
		'compressed_genotype_region'      => 0,
		'sample'                          => 1,
		'population'                      => 1,
		'individual'                      => 1,
		'individual_population'           => 1,
		'allele_code'                     => 1,
		'genotype_code'                   => 1,
		'meta_coord'                      => 1,
		'source'                          => 1,
	};
	
	# override this with options if provided
	if(defined($config->{tables})) {
		
		# reset
		$tables->{$_} = 0 foreach keys %$tables;
		
		# set include tables
		foreach my $table(split /\,/, $config->{tables}) {
			$tables->{$table} = 1 if defined($tables->{$table});
		}
	}
	
	if(defined($config->{skip_tables})) {
		
		# set skip tables
		foreach my $table(split /\,/, $config->{skip_tables}) {
			$tables->{$table} = 0 if defined($tables->{$table});
		}
	}
	
	# force some back in
	$tables->{$_} = 1 for qw/source meta_coord/;
	
	# special case for sample, we also want to set the other sample tables to on
	if($tables->{sample}) {
		$tables->{$_} = 1 for qw/population individual individual_population/;
	}
	
	# force population if user wants allele or population_genotype
	if($tables->{allele} || $tables->{population_genotype}) {
		$tables->{$_} = 1 for qw/population sample/;
	}
	
	# force individual tables for individual level data
	if($tables->{compressed_genotype_region} || $tables->{individual_genotype_multiple_bp} || $tables->{compressed_genotype_var}) {
		$tables->{$_} = 1 for qw/population individual individual_population sample variation variation_synonym variation_feature flanking_sequence/;
	}
	
	if($tables->{population_genotype} || $tables->{compressed_genotype_region} || $tables->{compressed_genotype_var}) {
		$tables->{$_} = 1 for qw/genotype_code variation variation_synonym variation_feature flanking_sequence/;
	}
	
	if($tables->{allele} || $tables->{genotype_code}) {
		$tables->{$_} = 1 for qw/allele_code variation variation_synonym variation_feature flanking_sequence/;
	}
	
	# won't be writing to these tables if only_existing mode
	if(defined $config->{only_existing}) {
		$tables->{$_} = 0 for qw/source variation variation_synonym variation_feature flanking_sequence/;
	}
	
	# check that at least one has been set
	die "ERROR: no tables left included\n" unless grep {$tables->{$_}} keys %$tables;
	
	$config->{tables} = $tables;
	
	die "ERROR: tmpdir not specified\n" if !defined $config->{tmpdir} && $tables->{compressed_genotype_region};
	$config->{tmpfile} ||= 'compress.txt';
	$ImportUtils::TMP_DIR  = $config->{tmpdir};
	$ImportUtils::TMP_FILE = $config->{tmpfile};
	
	
	$config->{reg} = 'Bio::EnsEMBL::Registry';
	
	# VEP stuff
	$config->{chunk_size}        ||= 50000;
	$config->{cache_region_size} ||= 1000000;
	$config->{compress}          ||= 'zcat';
	$config->{sa}                  = $config->{slice_adaptor};
	$config->{terms}               = 'SO';
	$config->{tr_cache}            = {};
	$config->{rf_cache}            = {};
	$config->{quiet}               = 1;
	$config->{original}            = 1;
	$config->{dir}                 = $ENV{'HOME'}.'/.vep/homo_sapiens/66';
	$config->{cache}               = 1;
	$config->{offline}             = 1;
	$config->{no_progress}         = 1;
	$config->{buffer_size}       ||= 1000;
	
	# get terminal width for progress bars
	my $width;
	
	# module may not be installed
	eval q{
		use Term::ReadKey;
	};
	
	if(!$@) {
		my ($w, $h);
		
		# module may be installed, but e.g.
		eval {
			($w, $h) = GetTerminalSize();
		};
		
		$width = $w if defined $w;
	}
	
	$width ||= 60;
	$width -= 12;
	$config->{terminal_width} = $width;
	
	return $config;
}

# reads config from a file
sub read_config_from_file {
    my $config = shift;
    my $file = shift;
    
    open CONFIG, $file or die "ERROR: Could not open config file \"$file\"\n";
    
    debug($config, "Reading configuration from $file") unless defined($config->{quiet});
    
    while(<CONFIG>) {
        next if /^\#/;
        my @split = split /\s+|\=/;
        my $key = shift @split;
        $key =~ s/^\-//g;
        
        if(defined($config->{$key}) && ref($config->{$key}) eq 'ARRAY') {
            push @{$config->{$key}}, @split;
        }
        else {
            $config->{$key} ||= $split[0];
        }
    }
    
    close CONFIG;
}


# main sub-routine does most of the code execution
sub main {
	
	my $config = shift;
	
	# log start time
	my $start_time = time();
	
	
	# SET UP VARIABLES
	##################
	
	my (
		%headers,
		$prev_seq_region,
		$genotypes,
		$var_counter,
		$start_time,
		@vf_buffer,
	);
	
	
	# CONNECT TO DBS
	################
	
	connect_to_dbs($config);
	
	# populate from SQL?
	if(defined($config->{sql}) && !defined($config->{forked})) {
		sql_populate($config, $config->{sql});
	}
	
	# get adaptors
	get_adaptors($config);
	
	# backup
	backup($config) if defined($config->{backup}) || defined($config->{move});
	
	# TEST MODE?
	############
	
	debug($config, "Running in test mode - will read first ", $config->{test}, " lines of input") if defined($config->{test});
	
	# DB PREP
	#########
	
	# get seq_region_id hash
	$config->{seq_region_ids} = get_seq_region_ids($config);
	
	# if failed, try and copy from core DB
	if(!scalar keys %{$config->{seq_region_ids}}) {
		
		copy_seq_region_from_core($config);
		
		# now reload
		$config->{seq_region_ids} = get_seq_region_ids($config);
	}
	
	die("ERROR: seq_region not populated\n") unless scalar keys %{$config->{seq_region_ids}};
	
	# get/set source_id
	die("ERROR: no source specified\n") if !(defined $config->{source}) && !defined($config->{only_existing});
	$config->{source_id} = get_source_id($config) unless defined($config->{only_existing});
	
	# get population object
	if($config->{tables}->{population}) {
		die("ERROR: no population specified\n") unless defined $config->{population} || defined $config->{panel};
		$config->{populations} = population($config);
	}
	
	# disable keys if requested
	if(defined $config->{disable_keys}) {
		debug($config, "Disabling keys");
		
		foreach my $table(qw(allele population_genotype)) {#grep {$config->{tables}->{$_}} keys %$config->{tables}) {
			$config->{dbVar}->do(qq{ALTER TABLE $table DISABLE KEYS;});
		}
	}
	
	# GET INPUT FILE HANDLE
	#######################
	
	# if we forked, already have file handle but need to reopen original file
	# to read data from the column definition headers
	if(defined($config->{forked})) {
		my $tmp_file_handle = get_input_file_handle($config);
		
		while(<$tmp_file_handle>) {
			chomp;
			next if /^##/;
			
			my @split = split /\t/;
			
			# column definition line
			if(/^#/) {
				%headers = %{parse_header($config, \@split)};
				last;
			}
		}
	}
	
	else {
		$config->{in_file_handle} = get_input_file_handle($config);
	}
	
	
	# PEDIGREE FILE
	###############
	
	$config->{pedigree} = pedigree($config) if defined($config->{pedigree});
	
	# MAIN FILE LOOP
	################
	
	my $in_file_handle = $config->{in_file_handle};
	
	my $last_skipped = 0;
	
	# read the file
	while(<$in_file_handle>) {
		chomp;
		
		# header lines
		next if /^##/;
		
		my @split = split /\t/;
		my $data;
		my $line = $_;
		
		# column definition line
		if(/^#/) {
			%headers = %{parse_header($config, \@split)};
		}
		
		# data
		else {
			
			# check we're not skipping loads in a row
			if($last_skipped > 100 && $last_skipped =~ /(5|0)00$/) {
				debug($config, "WARNING: Skipped last $last_skipped variants, are you sure this is running OK? Maybe --gp is enabled when it shouldn't be, or vice versa?");
			}
			
			# parse into a hash
			$data->{$_} = $split[$headers{$_}] for keys %headers;
			
			# skip non-variant lines
			next if $data->{ALT} eq '.';
			
			# parse info column
			my %info;	
			foreach my $chunk(split /\;/, $data->{INFO}) {
				my ($key, $val) = split /\=/, $chunk;
				$info{$key} = $val;
			}
			
			$data->{info} = \%info;
			
			# skip unwanted chromosomes
			#next if defined($config->{chrom_regexp}) && $data->{'#CHROM'} !~ m/$chrom_regexp/;
			
			# use VEP's parse_line to get a skeleton VF
			($data->{tmp_vf}) = @{parse_line($config, $line)};
			
			if(!defined($data->{tmp_vf})) {
				$config->{skipped}->{could_not_parse}++;
				$last_skipped++;
				next;
			}
			
			if(!defined($config->{seq_region_ids}->{$data->{tmp_vf}->{chr}})) {
				$config->{skipped}->{missing_seq_region}++;
				$last_skipped++;
				next;
			}
			
			next unless $data->{tmp_vf}->isa('Bio::EnsEMBL::Variation::VariationFeature');
			
			# sometimes ID has many IDs separated by ";", take the lowest rs number, otherwise the first
			if($data->{ID} =~ /\;/) {
				if($data->{ID} =~ /rs/) {
					$data->{ID} = (sort {(split("rs", $a))[-1] <=> (split("rs", $b))[-1]} split /\;/, $data->{ID})[0];
				}
				else {
					$data->{ID} = (split /\;/, $data->{ID})[0];
				}
			}
			
			
			# make a var name if none exists
			if($data->{ID} eq '.' || defined($config->{new_var_name})) {
				$data->{ID} =
					($config->{var_prefix} ? $config->{var_prefix} : 'tmp').
					'_'.$data->{'#CHROM'}.'_'.$data->{POS};
			}
			
			$data->{tmp_vf}->{variation_name} = $data->{ID};
			
			# parse genotypes
			$data->{genotypes} = get_genotypes($config, $data, \@split);
			
			# get variation object
			$data->{variation} = variation($config, $data);
			
			# get variation_feature object
			$data->{vf} = variation_feature($config, $data);
			
			# skip variation if no dbID
			if(!defined($data->{variation}->{dbID}) && !defined($config->{test})) {
				$config->{skipped}->{var_not_present}++;
				$last_skipped++;
				next;
			}
			
			# transcript variation
			#push @vf_buffer, $data->{vf};
			#if(scalar @vf_buffer == $config->{buffer_size}) {
			#	transcript_variation($config, \@vf_buffer);
			#	@vf_buffer = ();
			#}
			
			# alleles
			allele($config, $data) if $config->{tables}->{allele};
			
			# population genotypes
			population_genotype($config, $data) if $config->{tables}->{population_genotype};
			
			# individual genotypes
			individual_genotype($config, $data) if $config->{tables}->{compressed_genotype_var};
			
			# GENOTYPES BY REGION
			#####################
			
			# multi bp
			#if($config->{tables}->{individual_genotype_multiple_bp} && $force_multi && @{$data->{genotypes}}) {
			#	&multi_bp_genotype($dbVar, $data);
			#}
			
			# compressed by region
			if($config->{tables}->{compressed_genotype_region} && @{$data->{genotypes}}) {
				my $vf = $data->{vf};
				
				next unless defined($vf->{seq_region_id}) && defined($vf->{start});
				
				foreach my $gt(@{$data->{genotypes}}) {
					my $sample_id = $gt->individual->dbID;
					
					next if $gt->genotype_string =~ /\./;
					
					# add to compress hash for writing later
					if (!defined $genotypes->{$sample_id}->{region_start}){
						$genotypes->{$sample_id}->{region_start} = $vf->{start};
						$genotypes->{$sample_id}->{region_end} = $vf->{end};
					}
					
					# write previous data?
					#compare with the beginning of the region if it is within the DISTANCE of compression
					if (
						defined($genotypes->{$sample_id}->{genotypes}) &&
						(
							(abs($genotypes->{$sample_id}->{region_start} - $vf->{start}) > DISTANCE()) ||
							(abs($vf->{start} - $genotypes->{$sample_id}->{region_end}) > MAX_SHORT) ||
							(defined($prev_seq_region) && $vf->{seq_region_id} != $prev_seq_region) ||
							($vf->{start} - $genotypes->{$sample_id}->{region_end} - 1 < 0)
						)
					) {
						#snp outside the region, print the region for the sample we have already visited and start a new one
						print_file($config,$genotypes, $prev_seq_region, $sample_id);
						delete $genotypes->{$sample_id}; #and remove the printed entry
						$genotypes->{$sample_id}->{region_start} = $vf->{start};
					}
					
					if ($vf->{start} != $genotypes->{$sample_id}->{region_start}){
						#compress information
						my $blob = pack ("w",$vf->{start} - $genotypes->{$sample_id}->{region_end} - 1);
						$genotypes->{$sample_id}->{genotypes} .=
							escape($blob).
							escape(pack("w", $data->{variation}->dbID || 0)).
							escape(pack("w", $config->{individualgenotype_adaptor}->_genotype_code($gt->genotype)));
					}
					else{
						#first genotype starts in the region_start, not necessary the number
						$genotypes->{$sample_id}->{genotypes} =
							escape(pack("w", $data->{variation}->dbID || 0)).
							escape(pack("w", $config->{individualgenotype_adaptor}->_genotype_code($gt->genotype)));
					}
					
					$genotypes->{$sample_id}->{region_end} = $vf->{start};
				}
			}
			
			$prev_seq_region = $data->{vf}->{seq_region_id};
			$last_skipped = 0;
			
			$var_counter++;
			last if defined($config->{test}) && $var_counter == $config->{test};
			
			if(defined($config->{forked})) {
				debug($config, "Processed $var_counter lines (".$config->{forked}.")");
			}
			elsif($var_counter =~ /(5|0)00$/) {
				debug($config, "Processed $var_counter lines");
			}
		}
	}
	
	# clean up remaining genotypes and import
	if($config->{tables}->{compressed_genotype_region}) {
	
		debug($config, "Importing compressed genotype data");
		
		print_file($config,$genotypes, $prev_seq_region);
		&import_genotypes($config);
	}
	
	transcript_variation($config, \@vf_buffer) if @vf_buffer;
	
	# re-enable keys if requested
	if(defined $config->{disable_keys}) {
		debug($config, "Re-enabling keys");
		
		foreach my $table(qw(allele population_genotype)) {#grep {$config->{tables}->{$_}} keys %{$config->{tables}}) {
			$config->{dbVar}->do(qq{ALTER TABLE $table ENABLE KEYS;})
		}
	}
	
	#debug($config, "Skipped $skipped variations in the file\n");
	#debug($config, "Took ", time() - $start_time, "s to run\n");
	
	debug($config, "Updating meta_coord");
	meta_coord($config);
	
	my $max_length = (sort {$a <=> $b} map {length($_)} (keys %{$config->{skipped}}, keys %{$config->{rows_added}}))[-1];
	
	# rows added
	debug($config, (defined($config->{test}) ? "(TEST) " : "")."Rows added:");
	
	for my $key(sort keys %{$config->{rows_added}}) {
		debug($config, (defined($config->{forked}) ? "STATS\t" : "").$key.(' ' x (($max_length - length($key)) + 4)).$config->{rows_added}->{$key});
	}
	
	# vars skipped
	debug($config, "Lines skipped:");
	
	for my $key(sort keys %{$config->{skipped}}) {
		debug($config, (defined($config->{forked}) ? "SKIPPED\t" : "").$key.(' ' x (($max_length - length($key)) + 4)).$config->{skipped}->{$key});
	}
	
	debug($config, "Finished!".(defined($config->{forked}) ? " (".$config->{forked}.")" : ""));
}


sub run_forks {

	# check tabix is installed and working
	die "ERROR: tabix does not seem to be in your path - required for forking\n" unless `which tabix 2>&1` =~ /tabix$/;

	# remote files?
	my $filepath = $config->{input_file};
	
	if($filepath =~ /tp\:\/\//) {
		my $remote_test = `tabix $filepath 1:1-1 2>&1`;
		if($remote_test =~ /fail/) {
			die "$remote_test\nERROR: Could not find file or index file for remote annotation file $filepath\n";
		}
		elsif($remote_test =~ /get_local_version/) {
			debug($config, "Downloaded tabix index file for remote annotation file $filepath") unless defined($config->{quiet});
		}
	}
	
	debug($config, "Found tabix index file, forking OK");
	
	my @pids;
	
	my @chrs;
	open TMP, "tabix -l ".$config->{input_file}." | ";
	while(<TMP>) {
		chomp;
		push @chrs, $_;
	}
	close TMP;
	@chrs = reverse @chrs;
	
	## we need to scan upfront through the file to find the chrs we are parsing
	#my (%chr_hash, $num_lines);
	#
	#debug($config, "Scanning input file for chromosome list");
	#
	#open TMP, "zcat ".$config->{input_file}." | ";
	#while(<TMP>) {
	#	next if /^#/;
	#	my $chr = (split)[0];
	#	$chr_hash{$chr}++;
	#	$num_lines++;
	#}
	#close TMP;
	#
	#my @chrs = sort {$chr_hash{$a} <=> $chr_hash{$b}} keys %chr_hash;#(1..22,'X','Y','MT');
	
	my $string = '?';#$num_lines;
    #1 while $string =~ s/^(-?\d+)(\d\d\d)/$1,$2/;
	
	debug($config, "Done - found $string variants across ".(scalar @chrs)." chromosomes");
	
	# fork off a process to handle comms
	my $comm_pid = fork;
	
	if($comm_pid == 0) {
		my $c;
		my $finished = 0;
		
		while(<CHILD>) {
			if(/Processed/) {
				$c++;
				
				#my ($q, $n) = ($config->{quiet}, $config->{no_progress});
				#delete $config->{quiet};
				#delete $config->{no_progress};
				#progress($config, $c, $num_lines);
				#($config->{quiet}, $config->{no_progress}) = ($q, $n);
				if($c =~ /000$/) {
					debug({}, "Processed $c lines");
				}
			}
			elsif(/Finished/) {
				print $_;
				$finished++;
				last if $finished == @chrs;
			}
			elsif(/STATS/) {
				chomp;
				my @split = split /\s+/;
				$config->{rows_added}->{$split[-2]} += $split[-1];
			}
			elsif(/SKIPPED/) {
				chomp;
				my @split = split /\s+/;
				$config->{skipped}->{$split[-2]} += $split[-1];
			}
			elsif(/WARNING/) {
				print;
			}
		}
		close CHILD;
		
		delete $config->{quiet};
		delete $config->{no_progress};
		end_progress($config);
		
		# stats
		debug($config, "Rows added:");
		
		my $max_length = (sort {$a <=> $b} map {length($_)} (keys %{$config->{skipped}}, keys %{$config->{rows_added}}))[-1];
		
		for my $key(sort keys %{$config->{rows_added}}) {
			print $key.(' ' x (($max_length - length($key)) + 4)).$config->{rows_added}->{$key}."\n";
		}
		
		# vars skipped
		debug($config, "Lines skipped:");
		
		for my $key(sort keys %{$config->{skipped}}) {
			print $key.(' ' x (($max_length - length($key)) + 4)).$config->{skipped}->{$key}."\n";
		}
		
		exit(0);
	}
	elsif(!defined $comm_pid) {
		die("ERROR: Unable to fork communications process\n");
	}
	
	# now fork a process for each chromosome
	for my $chr(@chrs) {
		
		my $pid = fork;
		
		if($pid) {
			push @pids, $pid;
			
			# stop the next one doing backup
			delete $config->{backup} if defined($config->{backup});
			delete $config->{move} if defined($config->{move});
			
			# sleep to avoid conflicting inserts at beginning of forked processes
			sleep(10);
			
			# stop if max processes reached
			if(scalar @pids == $config->{fork}) {
				#debug($config, "Max processes (".$config->{fork}.") reached - waiting...");
				my $waiting_pid = shift @pids;
				waitpid($waiting_pid, 0);
			}
		}
		elsif($pid == 0) {
			
			debug($config, "Forking chr $chr");
			$config->{forked} = $chr;
			
			# point the file handle to a tabix pipe
			my $in_file_handle = FileHandle->new;
			
			$in_file_handle->open("tabix ".$config->{input_file}." $chr | ");
			$config->{in_file_handle} = $in_file_handle;
			
			# run the main sub
			main($config);
			
			close PARENT;
			
			# remember to exit!
			exit(0);
		}
		else {
			die("ERROR: Failed to fork");
		}
	}
	
	# wait for remaining processes to finish
	waitpid($_, 0) for @pids;
	
	# kill off the comm pid in case one of the other children died
	kill 9, $comm_pid;
	
	debug($config, "Finished all forks");
}


# connects to database
sub connect_to_dbs {
	if(defined($config->{database})) {
		$config->{dbVar} = DBI->connect( sprintf("DBI:mysql(RaiseError=>1):host=%s;port=%s;db=%s", $config->{host}, $config->{port}, $config->{database}), $config->{user}, $config->{password} );
	}
	else {
		
		# get registry
		my $reg = 'Bio::EnsEMBL::Registry';
		
		if(defined($config->{host}) && defined($config->{user})) {
			$reg->load_registry_from_db(-host => $config->{host}, -user => $config->{user}, -pass => $config->{password});
		}
		
		else {
			if(-e $config->{registry}) {
				$reg->load_all($config->{registry});
			}
			else {
				die "ERROR: could not read from registry file ".$config->{registry}."\n";
			}
		}
	
		# connect to DB
		my $vdba = $reg->get_DBAdaptor($config->{species},'variation')
			|| usage( "Cannot find variation db for ".$config->{species}." in ".$config->{registry_file} );
		$config->{dbVar} = $vdba->dbc->db_handle;
	
		debug($config, "Connected to database ", $vdba->dbc->dbname, " on ", $vdba->dbc->host, " as user ", $vdba->dbc->username);
	}
}

# fetches API adaptors and attaches them to config hash
sub get_adaptors {
	my $config = shift;
	
	# variation adaptors
	foreach my $type(qw(
		population
		individual
		variation
		variationfeature
		allele
		populationgenotype
		genotypecode
		attribute
		individualgenotype
		transcriptvariation
	)) {
		$config->{$type.'_adaptor'} = $config->{reg}->get_adaptor($config->{species}, "variation", $type);
		die("ERROR: Could not get $type adaptor\n") unless defined($config->{$type.'_adaptor'});
	}
	
	# special case, population genotype adaptor needs a pointer to allele adaptor for caching allele codes
	$config->{populationgenotype_adaptor}->{_allele_adaptor} = $config->{allele_adaptor};
	
	
	# core adaptors
	#if(defined($config->{tables}->{transcript_variation}) && $config->{tables}->{transcript_variation}) {
		$config->{slice_adaptor} = $config->{reg}->get_adaptor($config->{species}, "core", "slice");
		die("ERROR: Could not get slice adaptor\n") unless defined($config->{slice_adaptor});
		$config->{tva} = $config->{transcriptvariation_adaptor};
	#}
}


# gets input file handle
sub get_input_file_handle {
	my $config = shift;

	# define the filehandle to read input from
	my $in_file_handle = new FileHandle;
	
	if(defined($config->{input_file})) {
	
		# check defined input file exists
		die("ERROR: Could not find input file ", $config->{input_file}, "\n") unless -e $config->{input_file};
		
		if ($config->{input_file} =~ /\.gz$/){
			
			$in_file_handle->open("zcat ". $config->{input_file} . "  2>&1 | " ) or die("ERROR: Could not read from input file ", $config->{input_file}, "\n");
		}
		elsif ($config->{input_file} =~ /\.vcf$/){
			$in_file_handle->open( $config->{input_file} ) or die("ERROR: Could not read from input file ", $config->{input_file}, "\n");
		}
		else{
			die "ERROR: Not sure how to handle file type of ", $config->{input_file}, "\n";
		}
	
		debug($config, "Reading from file ", $config->{input_file});
	}
	
	# no file specified - try to read data off command line
	else {
		$in_file_handle = 'STDIN';
		debug($config, "Attempting to read from STDIN");
	}
	
	return $in_file_handle;
}

# populates DB from schema file
sub sql_populate {
	my $config = shift;
	my $sql_file = shift;
	
	my $sql;
	open SQL, $sql_file or die "ERROR: Could not read from SQL file $sql_file\n";
	
	my $comment = 0;
	
	while(<SQL>) {
		chomp;
		s/^\s+//g;
		s/\s*\#.*$//g;
		
		$comment = 1 if /^\/\*\*/;
		
		$sql .= $_." " unless $comment;
		
		$comment = 0 if /^\*\//;
	}
	$sql =~ s/\s$//g;
	$sql =~ s/\s+/ /g;
	$sql =~ s/;\s+/;/g;
	close SQL;
	
	if(defined($config->{test})) {
		debug($config, "(TEST) Executing SQL in $sql_file");
	}
	else {
		debug($config, "Executing SQL in $sql_file");
		foreach my $command(split ';', $sql) {
			$config->{dbVar}->do($command) or die $config->{dbVar}->errstr;
		}
	}
}

# backs up tables that we're going to write to
sub backup {
	my $config = shift;
	
	my $pid = $$;
	
	if(defined($config->{move})) {		
		foreach my $table(grep {$config->{tables}->{$_}} keys %{$config->{tables}}) {
			debug($config, (defined($config->{test}) ? "(TEST) " : "")."Renaming $table to $table\_$pid");
			
			if(!defined($config->{test})) {
				$config->{dbVar}->do(qq{RENAME TABLE $table TO $table\_$pid});
				$config->{dbVar}->do(qq{CREATE TABLE $table LIKE $table\_$pid});
			}
		}
	}
	else {
		foreach my $table(grep {$config->{tables}->{$_}} keys %{$config->{tables}}) {
			debug($config, (defined($config->{test}) ? "(TEST) " : "")."Backing up table $table as $table\_$pid");
			
			if(!defined($config->{test})) {
				$config->{dbVar}->do(qq{CREATE TABLE $table\_$pid LIKE $table});
				$config->{dbVar}->do(qq{INSERT INTO $table\_$pid SELECT * FROM $table});
			}
		}
	}
}

# copies seq_region entries from core DB
sub copy_seq_region_from_core {
	my $config = shift;
	
	debug($config, "Attempting to copy seq_region entries from core DB");
	
	my $cdba = $config->{reg}->get_DBAdaptor($config->{species},'core') or return {};
	my $dbh  = $cdba->dbc->db_handle;
	
	my $sth = $dbh->prepare(q{
		SELECT s.seq_region_id, s.coord_system_id, s.name
		FROM seq_region s, coord_system c
		WHERE s.coord_system_id = c.coord_system_id
		AND c.attrib LIKE '%default_version%'
		AND c.name = ?
	});
	$sth->execute($config->{coord_system});
	
	my ($sr, $cs, $name);
	$sth->bind_columns(\$sr, \$cs, \$name);
	
	my $vsth = $config->{dbVar}->prepare(q{
		INSERT INTO seq_region(seq_region_id, coord_system_id, name)
		VALUES (?, ?, ?)
	});
	
	$vsth->execute($sr, $cs, $name) while $sth->fetch();
}


# parses column definition line
sub parse_header {
	my $config     = shift;
	my $split_ref  = shift;
	
	my @split = @$split_ref;
	
	debug($config, "Parsing header line");
	
	my %headers;
	$headers{$split[$_]} = $_ for(0..$#split);
	
	# do sample stuff if required
	if($config->{tables}->{sample}) {
		
		# set location of first sample col
		if(defined($headers{FORMAT})) {
			$config->{first_sample_col} = $headers{FORMAT} + 1;
			
			# splice @split hash to get just individual IDs
			splice(@split, 0, $config->{first_sample_col});
			
			$config->{individuals} = individuals($config, \@split);
		}
		
		# if no sample data
		else {
			delete $config->{tables}->{$_} foreach qw(compressed_genotype_region compressed_genotype_var);
		}
	}
	
	return \%headers;
}

# gets seq_region_id to chromosome mapping from DB
sub get_seq_region_ids{
	my $config = shift;
	my $dbVar = $config->{dbVar};
	
	my ($seq_region_id, $chr_name, %seq_region_ids);
	my $sth = $dbVar->prepare(qq{SELECT seq_region_id, name FROM seq_region});
	$sth->execute;
	$sth->bind_columns(\$seq_region_id, \$chr_name);
	$seq_region_ids{$chr_name} = $seq_region_id while $sth->fetch;
	$sth->finish;
	
	if(defined($config->{test})) {
		debug($config, "Loaded ", scalar keys %seq_region_ids, " entries from seq_region table");
	}
	
	return \%seq_region_ids;
}



# gets source_id - retrieves if name already exists, otherwise inserts
sub get_source_id{
	my $config = shift;
	my $dbVar  = $config->{dbVar};
	my $source = $config->{source};
	my $desc   = $config->{desc};
	
	my $source_id;
	
	# check existing
	my $sth = $dbVar->prepare(qq{select source_id from source where name = ?});
	$sth->execute($source);
	$sth->bind_columns(\$source_id);
	$sth->fetch;
	$sth->finish;
	
	if(!defined($source_id)) {
		if(defined($config->{test})) {
			debug($config, "(TEST) Writing source name $source to source table");
		}
		else {
			$sth = $dbVar->prepare(qq{insert into source(name, description) values(?,?)});
			$sth->execute($source, $desc);
			$sth->finish();
			$source_id = $dbVar->last_insert_id(undef, undef, qw(source source_id));
		}
		
		$config->{rows_added}->{source}++;
	}
	
	return $source_id;
}



# gets population objects - retrieves if already exists, otherwise inserts relevant entries
sub population{
	my $config = shift;
	
	my @pops = ();
	
	if(defined($config->{panel})) {
		open PANEL, $config->{panel} or die "ERROR: Could not read from panel file ".$config->{panel}."\n";
		
		my $pop_inds = {};
		my $ind_pops = {};
		
		while(<PANEL>) {
			chomp;
			my @split = split /\s+|\,/;
			my $ind = shift @split;
			
			$ind = $config->{ind_prefix}.$ind;
			
			# make all individuals a member of top-level population if specified
			push @split, $config->{population} if defined($config->{population});
			
			foreach my $pop(@split) {
				$pop = $config->{pop_prefix}.$pop;
				$pop_inds->{$pop}->{$ind} = 1; 
				$ind_pops->{$ind}->{$pop} = 1;
			}
		}
		
		close PANEL;
		
		$config->{ind_pops} = $ind_pops;
		$config->{pop_inds} = $pop_inds;
		@pops = keys %$pop_inds;
	}
	
	elsif(defined $config->{population}) {
		push @pops, $config->{pop_prefix}.$config->{population};
	}
	
	die "ERROR: Population name not specified - use --population [population] or --panel [panel_file]\n" unless scalar @pops;
	
	# get a population adaptor
	my $pa = $config->{population_adaptor};
	
	# check GMAF pop is one of those we are adding
	if(defined($config->{gmaf})) {
		die "ERROR: Population specified using --gmaf (".$config->{gmaf}." is not one of those to be added; use \"--gmaf ALL\" to calculate GMAF from all individuals in the file\n" unless grep {$config->{gmaf} eq 'ALL' or $config->{gmaf} eq $_ or $config->{pop_prefix}.$config->{gmaf} eq $_} @pops;
	}
	
	my @return;
	
	foreach my $pop_name(@pops) {
		
		# attempt fetch by name
		my $pop = $pa->fetch_by_name($pop_name);
		
		# not found, create one
		if(!defined($pop)) {
			$pop = Bio::EnsEMBL::Variation::Population->new(
				-name    => $pop_name,
				-adaptor => $pa,
			);
			
			if(defined($config->{test})) {
				debug($config, "(TEST) Writing population object named $pop_name");
			}
			else {
				$pa->store($pop);
			}
			
			$config->{rows_added}->{sample}++;
			$config->{rows_added}->{population}++;
		}
		
		push @return, $pop;
	}
	
	return \@return;
}

# parses pedigree file to get family relationships and genders
sub pedigree {
	my $config = shift;
	
	my $file = $config->{pedigree};
	my $ped = {};
	my %genders = (
		1 => 'Male',
		2 => 'Female',
	);
	
	open IN, $file or die "ERROR: Could not read from pedigree file $file\n";
	while(<IN>) {
		chomp;
		
		my ($family, $ind, $dad, $mum, $sex) = split;
		
		# add ind prefixes
		$_ = $config->{ind_prefix}.$_ for ($ind, $dad, $mum);
		
		$ped->{$ind}->{gender} = defined($sex) ? ($genders{$sex} || 'Unknown') : 'Unknown';
		$ped->{$ind}->{father} = $dad if defined($dad) && $dad;
		$ped->{$ind}->{mother} = $mum if defined($mum) && $mum;
	}
	close FILE;
	
	return $ped;
}

sub individuals {
	my $config    = shift;
	my $split_ref = shift;
	
	# get an individual adaptor
	my $ia = $config->{individual_adaptor};
	
	# populate %ind_pops hash if it doesn't exist (this will happen when using --population but no panel file)
	if(!exists($config->{ind_pops})) {
		my %ind_pops = map { $config->{ind_prefix}.$_ => {$config->{pop_prefix}.$config->{population} => 1} } @$split_ref;
		$config->{ind_pops} = \%ind_pops;
	}
	
	# need the relationship to go both ways (allele/pop_genotype uses this way round later on)
	if(!exists($config->{pop_inds})) {
		my %pop_inds = map { $config->{pop_prefix}.$config->{population} => {$config->{ind_prefix}.$_ => 1} } @$split_ref;
		$config->{pop_inds} = \%pop_inds;
	}
	
	my (@individuals, %ind_objs);
	
	# only add the individuals that were defined in the panel file (this will be all if no panel file)
	my @sorted = grep {defined $config->{ind_pops}->{$_}} @$split_ref;
	
	# if we have pedigree, we need to sort it so the parent individuals get added first
	if(defined($config->{pedigree}) && ref($config->{pedigree}) eq 'HASH') {
		@sorted = sort {
			(
				defined($config->{pedigree}->{$config->{ind_prefix}.$a}->{father}) +
				defined($config->{pedigree}->{$config->{ind_prefix}.$a}->{mother})
			) <=> (
				defined($config->{pedigree}->{$config->{ind_prefix}.$b}->{father}) +
				defined($config->{pedigree}->{$config->{ind_prefix}.$b}->{mother})
			)
		} @$split_ref;
	}
	
	# get population objects in hash indexed by name
	my %pop_objs = map {$_->name => $_} @{$config->{populations}};
	
	foreach my $individual_name(@sorted) {
		
		# add individual prefix if defined
		$individual_name = $config->{ind_prefix}.$individual_name;
		
		my $inds = $ia->fetch_all_by_name($individual_name);
		my $ind;
		
		if(scalar @$inds > 1) {
			die "ERROR: Multiple individuals with name $individual_name found, cannot continue\n";
		}
		elsif(scalar @$inds == 1) {
			$ind = $inds->[0];
		}
		
		# create new
		else {
			
			$ind = Bio::EnsEMBL::Variation::Individual->new(
				-name            => $individual_name,
				-adaptor         => $ia,
				-type_individual => 'outbred',
				-display         => 'UNDISPLAYABLE',
			);
			$ind->{populations} = [map {$pop_objs{$_}} keys %{$config->{ind_pops}->{$individual_name}}];
			
			# add data from pedigree file
			if(defined($config->{pedigree}) && ref($config->{pedigree}) eq 'HASH' && (my $ped = $config->{pedigree}->{$individual_name})) {
				$ind->{gender}            = $ped->{gender} if defined($ped->{gender});
				$ind->{father_individual} = $ind_objs{$ped->{father}} if defined($ped->{father});
				$ind->{mother_individual} = $ind_objs{$ped->{mother}} if defined($ped->{mother});
			}
			
			if($config->{tables}->{individual}) {
				if(defined($config->{test})) {
					debug($config, "(TEST) Writing individual object named $individual_name");
				}
				else {				
					$ia->store($ind);
				}
				
				$config->{rows_added}->{individual}++;
			}
		}
		
		push @individuals, $ind;
		$ind_objs{$individual_name} = $ind;
	}
	
	return \@individuals;
}




# gets variation object - retrieves if already exists, otherwise creates and writes to DB
sub variation {
	my $config = shift;
	my $data   = shift;
	my $var_id = $data->{ID};
	
	# try and fetch existing variation object
	my $var = $config->{variation_adaptor}->fetch_by_name($var_id);
	
	# get ref to tmp vf object created by VEP parse_vcf
	my $vf = $data->{tmp_vf};
	
	# get class
	my $so_term  = SO_variation_class($vf->allele_string, 1);
	my $class_id = $config->{attribute_adaptor}->attrib_id_for_type_value('SO_term', $so_term);
	
	# otherwise create new one
	if(!defined($var) && !defined($config->{only_existing})) {
		$var = Bio::EnsEMBL::Variation::Variation->new_fast({
			name             => $var_id,
			source           => $config->{source},
			is_somatic       => 0,
			ancestral_allele => $data->{info}->{AA} eq '.' ? undef : $data->{info}->{AA}
		});
		
		# add in some hacky stuff so flanking sequence gets written
		$var->{source_id}             = $config->{source_id};
		$var->{seq_region_id}         = $config->{seq_region_ids}->{$vf->{chr}};
		$var->{seq_region_strand}     = 1;
		$var->{up_seq_region_start}   = $vf->{start} - $config->{flank};
		$var->{up_seq_region_end}     = $vf->{start} - 1;
		$var->{down_seq_region_start} = $vf->{end} + 1;
		$var->{down_seq_region_end}   = $vf->{end} + $config->{flank};
		
		# class
		$var->{class_attrib_id} = $class_id;
		
		#$config->{variation_adaptor}->store($var);
	}
	
	# attach the variation to the variation feature
	$vf->{variation} = $var;
	
	return $var;
}



# gets variation feature object
sub variation_feature {
	my $config = shift;
	my $data = shift;
	
	my $dbVar = $config->{dbVar};
	my $vf = $data->{tmp_vf};
	
	my @new_alleles = split /\//, $vf->allele_string;
	
	my $vfa = $config->{variationfeature_adaptor};
	
	my $existing_vfs = $vfa->_fetch_all_by_coords($config->{seq_region_ids}->{$vf->{chr}}, $vf->{start}, $vf->{end});
	
	my ($existing_vf, $new_allele_string);
	
	# if there's more than one, choose the lowest rs number
	if(scalar @$existing_vfs > 1) {
		my @names = map {$_->variation_name} @$existing_vfs;
		$_ =~ s/^rs//g for @names;
		my %sorting = map {$_ => $names[$_]} (0..$#names);
		$existing_vf = $existing_vfs->[(sort {$sorting{$a} <=> $sorting{$b}} keys %sorting)[0]];
	}
	
	# just one existing, merge in novel alleles?
	elsif(scalar @$existing_vfs) {
		$existing_vf = $existing_vfs->[0];
	}
	
	if(defined $existing_vf) {
		unless(defined $config->{only_existing}) {
			my @existing_alleles = split /\//, $existing_vf->allele_string;
			
			# compare ref alleles - we don't want to merge if they differ
			#next unless $existing_alleles[0] eq $new_alleles[0];
			
			# copy to hash to see which alleles are novel
			my %combined_alleles;
			$combined_alleles{$_}++ for (@existing_alleles, @new_alleles);
			
			if(scalar keys %combined_alleles != scalar @existing_alleles) {
				
				# create new allele string and update variation_feature
				# not really ideal to be doing direct SQL here but will do for now
				$new_allele_string =
					$existing_vf->allele_string.
					'/'.
					(join /\//, grep {$combined_alleles{$_} == 1} @new_alleles);
				
				if(defined($config->{test})) {
					debug($config, "(TEST) Changing allele_string for ", $existing_vf->variation_name, " from ", $existing_vf->allele_string, " to $new_allele_string");
				}
				else {
					my $sth = $dbVar->prepare(qq{
						UPDATE variation_feature
						SET allele_string = ?
						WHERE variation_feature_id = ?
					});
					$sth->execute($new_allele_string, $existing_vf->dbID);
					$sth->finish;
				}
				
				$config->{rows_added}->{variation_feature_allele_string_merged}++;
			}
			
			
			# we also need to add a synonym entry if the variation has a new name
			if($existing_vf->variation_name ne $data->{ID}) {
				
				if(defined($config->{test})) {
					debug($config, "(TEST) Adding ", $data->{ID}, " to variation_synonym as synonym for ", $existing_vf->variation_name);
				}
				else {
					my $sth = $dbVar->prepare(qq{
						INSERT IGNORE INTO variation_synonym(
							variation_id,
							source_id,
							name
						)
						VALUES(?, ?, ?)
					});
					
					$sth->execute(
						$existing_vf->{_variation_id} || $existing_vf->variation->dbID,
						$config->{source_id},
						$data->{ID}
					);
					$sth->finish;
				}
				
				$config->{rows_added}->{variation_synonym}++;
			}
		}
		
		# point the variation object to the existing one
		$data->{variation} = $existing_vf->variation;
		
		# add GMAF?
		if(defined($config->{gmaf}) && !defined($data->{variation}->minor_allele_frequency)) {
			add_gmaf($config, $data, $data->{variation});
			
			if(defined($config->{test})) {
				debug($config, "(TEST) Updating variation ", $data->{variation}->name, " with GMAF data");
			}
			else {
				$config->{variation_adaptor}->update($data->{variation});
			}
		}
		
		# set to return the existing vf
		$vf = $existing_vf;
	}
	
	# otherwise we need to store the object we've created
	elsif(!defined($config->{only_existing})) {
		
		# add GMAF to variation object?
		add_gmaf($config, $data, $data->{variation}) if defined($config->{gmaf});
		
		# first store the variation object
		if(defined($config->{test})) {
			debug($config, "(TEST) Writing variation object named ", $data->{variation}->name) unless defined($data->{variation}->dbID);
		}
		else {
			$config->{variation_adaptor}->store($data->{variation}) unless defined($data->{variation}->dbID);
		}
		
		$config->{meta_coord}->{flanking_sequence} = undef;
		$config->{rows_added}->{variation}++;
		
		# get class
		my $so_term = SO_variation_class($vf->allele_string, 1);
		
		# add in some info needed (since we won't have a slice)
		$vf->{seq_region_id}   = $config->{seq_region_ids}->{$vf->{chr}};
		$vf->{source_id}       = $config->{source_id};
		$vf->{is_somatic}      = 0;
		$vf->{class_attrib_id} = $config->{attribute_adaptor}->attrib_id_for_type_value('SO_term', $so_term);
		
		# now store the VF
		if(defined($config->{test})) {
			debug($config, "(TEST) Writing variation_feature object named ", $vf->variation_name);
		}
		else {
			$vfa->store($vf);
		}
		
		# update meta_coord stat
		$config->{meta_coord}->{variation_feature} = $vf->{end} - $vf->{start} + 1 if
			!defined($config->{meta_coord}->{variation_feature}) or
			$vf->{end} - $vf->{start} + 1 > $config->{meta_coord}->{variation_feature};
		
		$config->{rows_added}->{variation_feature}++;
	}
	
	return $vf;
}


# transcript_variation
sub transcript_variation {
	my $config = shift;
	my $vfs    = shift;
	
	# update meta_coord stat
	$config->{meta_coord}->{transcript_variation} = undef;
	
	$DB::single = 1;
	
	# get a slice for the VF
	#my $slice = $config->{slice_adaptor}->fetch_by_region("chromosome", $vf->{chr});
	#$vf->{slice} = $slice;
	
	#my $dbID = $vf->dbID;
	#delete $vf->{dbID};
	
	waitpid($config->{tv_pid}, 0) if defined($config->{tv_pid});
	
	my $pid = fork;
	
	# parent
	if($pid) {
		$config->{tv_pid} = $pid;
		$config->{transcriptvariation_adaptor}->dbc->reconnect;
		return;
	}
	
	elsif($pid == 0) {
		
		#debug($config, "Doing TV");
		
		get_all_consequences($config, $vfs, $config->{tr_cache}, $config->{rf_cache});
		
		#debug($config, "Finished TV - writing to DB");
		
		foreach my $vf(@$vfs) {
			foreach my $tv(@{$vf->get_all_TranscriptVariations}) {
				#$vf->{dbID} ||= $dbID;
				
				if(defined($config->{test})) {
					debug($config, "(TEST) Writing transcript_variation object for variation ", $vf->variation_name, ", transcript ", $tv->transcript->stable_id);
				}
				else {
					$config->{transcriptvariation_adaptor}->store($tv);
				}
				
				$config->{rows_added}->{transcript_variation}++;
			}
		}
		
		#debug($config, "Finished writing to DB");
		
		exit(0);
	}
	
	else {
		die("ERROR: Could not fork\n");
	}
}


# get genotypes
sub get_genotypes {
	my $config = shift;
	my $data   = shift;
	my $split  = shift;
	
	my @alleles = split /\//, ($data->{vf} || $data->{tmp_vf})->allele_string;
	my @genotypes;
	
	for my $i(9..((scalar @$split) - 1)) {
		my @bits;
		my $gt = (split /\:/, $split->[$i])[0];
		foreach my $bit(split /\||\/|\\/, $gt) {
			push @bits, ($bit eq '.' ? '.' : $alleles[$bit]);
		}
		
		if(scalar @bits) {
			my $gt_obj = Bio::EnsEMBL::Variation::IndividualGenotype->new_fast({
				variation => $data->{variation},
				individual => $config->{individuals}->[$i-9],
				genotype => \@bits
			});
			
			push @genotypes, $gt_obj;
		}
	}
	
	return \@genotypes;
}


# adds GMAF to variation object
sub add_gmaf {
	my $config = shift;
	my $data   = shift;
	my $var    = shift;
	
	my @alleles = split /\//, $data->{tmp_vf}->allele_string;
	
	# at the moment we can only store GMAF for SNPs
	return unless scalar(grep {length($_) == 1} @alleles) == scalar @alleles;
	
	my (%freqs, %counts, $total);
	
	if(defined($data->{genotypes})) {
		map {$counts{$_}++}
			map {@{$_->genotype}}
			grep {
				$config->{gmaf} eq 'ALL' ||
				$config->{pop_inds}->{$config->{gmaf}}->{$_->individual->name} ||
				$config->{pop_inds}->{$config->{pop_prefix}.$config->{gmaf}}->{$_->individual->name}
			}
			@{$data->{genotypes}};
			
		$total += $_ for values %counts;
		%freqs = map {$_ => (defined($counts{$_}) ? ($counts{$_} / $total) : 0)} @alleles;
		
		if(%freqs && %counts) {
			$var->{minor_allele} = (sort {$freqs{$a} <=> $freqs{$b}} keys %freqs)[0];
			$var->{minor_allele_frequency} = (sort {$a <=> $b} values %freqs)[0];
			$var->{minor_allele_count} = (sort {$a <=> $b} values %counts)[0];
		}
	}
}


# allele table
sub allele {
	my $config = shift;
	my $data   = shift;
	
	my @alleles = split /\//, $data->{vf}->allele_string;
	
	foreach my $pop(@{$config->{populations}}) {
		
		# frequencies
		my @freqs;
		
		#if(defined($config->{info}->{AF})) {
		#	@freqs = split /\,/, $config->{info}->{AF};
		#	my $total_alt_freq = 0;
		#	$total_alt_freq += $_ for @freqs;
		#	unshift @freqs, 1 - $total_alt_freq;
		#}
		
		my (%counts, $total);
		if(defined($data->{genotypes})) {
			map {$counts{$_}++}
				map {@{$_->genotype}}
				grep {$config->{pop_inds}->{$pop->name}->{$_->individual->name}}
				@{$data->{genotypes}};
				
			$total += $_ for values %counts;
			@freqs = map {defined($counts{$_}) ? ($counts{$_} / $total) : 0} @alleles;
		}
		
		for my $i(0..$#alleles) {
			my $allele = Bio::EnsEMBL::Variation::Allele->new_fast({
				allele     => $alleles[$i],
				count      => scalar keys %counts ? $counts{$alleles[$i]} : undef,
				frequency  => @freqs ? $freqs[$i] : undef,
				population => $pop,
				variation  => $data->{variation}
			});
			
			if(defined($config->{test})) {
				debug($config, "(TEST) Writing allele object for variation ", $data->{variation}->name, ", allele ", $alleles[$i], ", population ", $pop->name, " freq ", (@freqs ? $freqs[$i] : "?"));
			}
			else {
				$config->{allele_adaptor}->store($allele);
			}
			
			$config->{rows_added}->{allele}++;
		}
	}
}


# population genotype table
sub population_genotype {
	my $config = shift;
	my $data   = shift;
	
	foreach my $pop(@{$config->{populations}}) {
	
		my %freqs;
		
		my (%counts, $total);
		if(defined($data->{genotypes})) {
			map {$counts{$_}++}
				grep {$_ !~ /\./}
				map {$_->genotype_string}
				grep {$config->{pop_inds}->{$pop->name}->{$_->individual->name}}
				@{$data->{genotypes}};
			$total += $_ for values %counts;
			%freqs = map {$_ => ($counts{$_} / $total)} keys %counts;
		}
		
		return unless scalar keys %freqs;
		
		foreach my $gt_string(keys %freqs) {
			
			# skip "missing" genotypes
			next if $gt_string =~ /\./;
			
			my $popgt = Bio::EnsEMBL::Variation::PopulationGenotype->new_fast({
				genotype => [split /\|/, $gt_string],
				population => $pop,
				variation => $data->{variation},
				frequency => $freqs{$gt_string},
				count => $counts{$gt_string}
			});
			
			
			if(defined($config->{test})) {
				debug($config, "(TEST) Writing population_genotype object for variation ", $data->{variation}->name, ", genotype ", $gt_string, ", population ", $pop->name, " freq ", ($freqs{$gt_string} || "?"));
			}
			else {
				$config->{populationgenotype_adaptor}->store($popgt);
			}
			
			$config->{rows_added}->{population_genotype}++;
		}
	}
}

sub individual_genotype {
	my $config = shift;
	my $data   = shift;
	
	my @gts = grep {$_->genotype_string !~ /\./} @{$data->{genotypes}};
	
	if(defined($config->{test})) {
		debug($config, "(TEST) Writing ", scalar @gts, " genotype objects for variation ", $data->{variation}->name);
	}
	else {
		my $rows_added = $config->{individualgenotype_adaptor}->store(\@gts);
		$config->{rows_added}->{compressed_genotype_var} += $rows_added;	
	}
	
	$config->{rows_added}->{individual_genotype} += scalar @gts;
}

# imports genotypes from tmp file to compressed_genotype_region
sub import_genotypes{
	my $config = shift;
	
	# update meta_coord stat
	$config->{meta_coord}->{compressed_genotype_region} = DISTANCE + 1;
	
	if(defined($config->{test})) {
		debug($config, "(TEST) Loading compressed genotypes from temporary file into database");
	}
	else {
		$config->{compress_out}->close if defined($config->{compress_out});
		my $call = "mv ".$config->{tmpdir}."/compressed_genotype_".$$.".txt ".$config->{tmpdir}."/".$config->{tmpfile};
		system($call);
		load($config->{dbVar},qw(compressed_genotype_region sample_id seq_region_id seq_region_start seq_region_end seq_region_strand genotypes));
	}
}

sub open_compressed_output {
	my $config = shift;
	my $file_handle = FileHandle->new("> ".$config->{tmpdir}."/compressed_genotype_".$$.".txt");
	$config->{compress_out} = $file_handle;
}

# dumps compressed data from hash to temporary file
sub print_file{
    my $config = shift;
    my $genotypes = shift;
    my $seq_region_id = shift;
    my $sample_id = shift;
	
	# load file handle if not defined
	open_compressed_output($config) unless defined $config->{compress_out};
	
	my $file_handle = $config->{compress_out};
	
	if(defined($config->{test})) {
		debug($config, "(TEST) Writing genotypes for ", (scalar keys %$genotypes), " individuals to temp file");
	}
	else {
		if (!defined $sample_id){
			#new chromosome, print all the genotypes and flush the hash
			foreach my $sample_id (keys %{$genotypes}){
				print $file_handle join("\t",
					$sample_id,
					$seq_region_id,
					$genotypes->{$sample_id}->{region_start},
					$genotypes->{$sample_id}->{region_end},
					1,
					$genotypes->{$sample_id}->{genotypes}) . "\n";
				
				$config->{rows_added}->{compressed_genotype_region}++;
			}
		}
		else{
			#only print the region corresponding to sample_id
			print $file_handle join("\t",
				$sample_id,
				$seq_region_id,
				$genotypes->{$sample_id}->{region_start},
				$genotypes->{$sample_id}->{region_end},
				1,
				$genotypes->{$sample_id}->{genotypes}) . "\n";
			
			$config->{rows_added}->{compressed_genotype_region}++;
		}
	}
}

# populates meta_coord table
sub meta_coord {
	my $config = shift;
	
	return unless scalar keys %{$config->{meta_coord}};
	
	# get coord system ID
	my $csa = $config->{reg}->get_adaptor($config->{species}, "core", "coordsystem");
	my $cs = $csa->fetch_by_name($config->{coord_system});
	return unless defined $cs;
	
	my $qsth = $config->{dbVar}->prepare(q{
		SELECT max_length
		FROM meta_coord
		WHERE table_name = ?
		AND coord_system_id = ?
	});
	
	my $usth = $config->{dbVar}->prepare(q{
		UPDATE meta_coord
		SET max_length = ?
		WHERE table_name = ?
		AND coord_system_id = ?
	});
	
	my $isth = $config->{dbVar}->prepare(q{
		INSERT INTO meta_coord (
			table_name, coord_system_id, max_length
		) VALUES (?,?,?)
	});
	
	foreach my $table(keys %{$config->{meta_coord}}) {
		my $existing_length;
		
		$qsth->execute($table, $cs->dbID);
		$qsth->bind_columns(\$existing_length);
		$qsth->fetch();
		
		if(defined($existing_length)) {
			# row exists, new length greater
			if(defined($config->{meta_coord}->{$table}) and $existing_length < $config->{meta_coord}->{$table}) {
				
				if(defined($config->{test})) {
					debug($config, "(TEST) Updating meta_coord entry for $table");
				}
				else {
					$usth->execute($config->{meta_coord}->{$table}, $table, $cs->dbID);
				}
			}
		}
		
		# row doesn't exist
		else {
			if(defined($config->{test})) {
				debug($config, "(TEST) Writing meta_coord entry for $table");
			}
			else {
				$isth->execute($table, $cs->dbID, $config->{meta_coord}->{$table});
			}
		}
	}
	
	$qsth->finish;
	$usth->finish;
	$isth->finish;
}

# prints usage message
sub usage {
	my $usage =<<END;
Usage:
perl import_vcf.pl [arguments]

Options
-h | --help           Display this message and quit

-i | --input_file     Input file - if not specified, attempts to read from STDIN
--tmpdir              Temporary directory to write genotype dump file. Required if
                      writing to compressed_genotype_region
--tmpfile             Name for temporary file [default: compress.txt]

--config              Specify a config file

--test [n]            Run in test mode on first n lines of file. No database writes
                      are done, and any that would be done are output as status
					  messages

--species             Species to use [default: "human"]
--source              Name of source [required]
--source_description  Description of source [optional]
--population          Name of population for all individuals in file
--panel               Panel file containing individual population membership. One or
                      more of --population or --panel is required. Frequencies are
					  calculated for each population specified. Individuals may belong
					  to more than one population
--pedigree            Pedigree file containing family relationships and individual
                      genders
					  
--gmaf [ALL|pop]      Add global allele frequency data. "--gmaf ALL" uses all
                      individuals in the file; specifying any other population name
					  will use the selected population as the GMAF.

--ind_prefix          Prefix added to individual names [default: not used]
--pop_prefix          Prefix added to population names [default: not used]
--var_prefix          Prefix added to constructed variation names [default: not used]

--create_name         Always create a new variation name i.e. don't use ID column
--chrom_regexp        Limit processing to CHROM columns matching regexp

-f | --flank          Size of flanking sequence [default: 200]
--gp                  Use GP tag from INFO column to get coords

--tables              Comma-separated list of tables to include when writing to DB
                      [default: all tables included]
--skip_tables         Comma-separated list of tables to exclude when writing to DB.
                      Takes precedence over --tables (i.e. any tables named in --tables
                      and --skip_tables will be skipped)

--only_existing       Only write to tables when an existing variant is found. Existing
                      can be a variation with the same name, or a variant with the same
					  location and alleles

-r | --registry       Registry file to use defines DB connections. Defining a registry
                      file overrides the connection settings below
-d | --db_host        Manually define database host
-u | --user           Database username
--password            Database password

--sql                 Specify SQL file to create tables. Usually found in the
                      ensembl-variation CVS checkout, as sql/tables.sql
--coord_system        If the seq_region table is not populated, by default the script
                      will attempt to copy seq_region entries from a Core database
					  specified in the registry file. The seq_region entries from the
					  selected coord_system will be copied and used
					  [default: chromosome]
--backup              Backup all affected tables before import
--move                Move all affected tables to backed up names and replace with
                      empty tables
					  
--fork [n]            Fork off n simultaneous processes, each dealing with one
                      chromosome from the input file. Input file must be bgzipped and
					  tabix indexed. 10 processes is usually optimal. [default: 1]
END

	print $usage;
}



# gets time
sub getTime() {
	my @time = localtime(time());

	# increment the month (Jan = 0)
	$time[4]++;

	# add leading zeroes as required
	for my $i(0..4) {
		$time[$i] = "0".$time[$i] if $time[$i] < 10;
	}

	# put the components together in a string
	my $time =
 		($time[5] + 1900)."-".
 		$time[4]."-".
 		$time[3]." ".
		$time[2].":".
		$time[1].":".
		$time[0];

	return $time;
}



# prints debug output with time
sub debug {
	my $config = shift;
	my $text = (@_ ? (join "", @_) : "No message");
	my $time = getTime;
	
	if(defined $config->{forked}) {
		print PARENT $time." - ".$text.($text =~ /\n$/ ? "" : "\n");
	}
	else {
		print $time." - ".$text.($text =~ /\n$/ ? "" : "\n");
	}
} 



# $special_characters_escaped = printable( $source_string );
sub escape ($) {
	local $_ = ( defined $_[0] ? $_[0] : '' );
	s/([\r\n\t\\\"])/\\$Printable{$1}/sg;
	return $_;
}
