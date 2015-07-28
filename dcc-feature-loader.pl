#!/usr/bin/perl -w

use v5.12;
use warnings qw(all);
no warnings qw(experimental);
use strict;
use diagnostics;

use Config::IniFiles;
use FindBin;
use lib $FindBin::Bin."/model/schema+tools/lib";
use lib $FindBin::Bin."/libs";

use Carp;
use File::Basename;
use File::Spec;
use IO::Handle;
use Net::FTP::AutoReconnect;
use URI;

use BP::Model;
use BP::Loader::CorrelatableConcept;
use BP::Loader::Tools;
use BP::Loader::Mapper;
use BP::Loader::Mapper::Autoload::Relational;
use BP::Loader::Mapper::Autoload::Elasticsearch;
use BP::Loader::Mapper::Autoload::MongoDB;

use BP::DCCLoader::WorkingDir;
use BP::DCCLoader::Parsers::EnsemblGTParser;

use TabParser;

use constant DCC_LOADER_SECTION => 'dcc-loader';

use constant {
	ENSEMBL_FTP_BASE_TAG	=> 'ensembl-ftp-base-uri',
	GENCODE_FTP_BASE_TAG	=> 'gencode-ftp-base-uri',
	REACTOME_BASE_TAG	=> 'reactome-base-uri',
	GENCODE_GTF_FILE_TAG	=> 'gencode-gtf',
	REACTOME_BUNDLE_TAG	=> 'reactome-bundle',
	ENSEMBL_SQL_FILE	=> 'homo_sapiens_core_{EnsemblVer}_{GRChVer}.sql.gz',
	ENSEMBL_SEQ_REGION_FILE	=> 'seq_region.txt.gz',
	ENSEMBL_GENE_FILE	=> 'gene.txt.gz',
	ENSEMBL_TRANSCRIPT_FILE	=> 'transcript.txt.gz',
	ENSEMBL_XREF_FILE	=> 'xref.txt.gz',
	REACTOME_INTERACTIONS_FILE	=> 'homo_sapiens.interactions.txt.gz',
	ANONYMOUS_USER	=> 'ftp',
	ANONYMOUS_PASS	=> 'guest@',
};

sub parseGTF(@);
sub parseReactomeInteractions($$$$$);

#####
# Method bodies
#####
sub parseGTF(@) {
	my(
		$payload,
		$chro,
		undef, # source
		$feature, # feature
		$chromosome_start,
		$chromosome_end,
		undef,
		$chromosome_strand,
		undef, # frame
		$attributes_str, # attributes following .ace format
	) = @_;
	
	my($p_ENShash,$p_mappers,$chroCV,$testmode) = @{$payload};
	
	my %attributes = ();
	
	#print STDERR "DEBUG: ",join(" ",@_),"\n"  unless(defined($attributes_str));
	my @tokens = split(/\s*;\s*/,$attributes_str);
	foreach my $token (@tokens) {
		my($key,$value) = split(/\s+/,$token,2);
		
		# Removing double quotes
		$value =~ tr/"//d;
		
		$attributes{$key} = $value;
	}
	
	my $p_regionData = undef;
	my $local = 1;
	
	my $ensIdKey = undef;
	my $p_ensFeatures = undef;
	if($feature eq 'gene') {
		$ensIdKey = 'gene_id';
		$p_ensFeatures = ['gene_name','havana_gene'];
	} else {
		$ensIdKey = 'transcript_id';
		$p_ensFeatures = ['transcript_name','havana_transcript','ccdsid'];
	}
	
	my $fullEnsemblId = $attributes{$ensIdKey};
	my $ensemblId = substr($fullEnsemblId,0,index($fullEnsemblId,'.'));
		
	if($feature eq 'gene' || $feature eq 'transcript') {
		if(exists($p_ENShash->{$ensemblId})) {
			$p_regionData = $p_ENShash->{$ensemblId};
			$local = undef;
		}
	}
	
	if($local) {
		my $term = $chroCV->getTerm($chro);
		if($term) {
			$p_regionData = {
				#$fullEnsemblId,
				'feature_cluster_id'	=> $attributes{'gene_id'},
				'chromosome'	=> $term->key(),
				'chromosome_start'	=> $chromosome_start,
				'chromosome_end'	=> $chromosome_end,
				'symbol'	=> [$fullEnsemblId,$ensemblId],
				'feature'	=> $feature
			};
		}
	}
	
	if($p_regionData) {
		foreach my $ensFeature (@{$p_ensFeatures}) {
			push(@{$p_regionData->{symbol}},$attributes{$ensFeature})  if(exists($attributes{$ensFeature}));
		}
		
		# Last, store it!!!
		if($local) {
			foreach my $mapper (@{$p_mappers}) {
				my $entorp = $mapper->validateAndEnactEntry($p_regionData);
				unless($testmode) {
					my $destination = $mapper->getInternalDestination();
					my $bulkData = $mapper->_bulkPrepare($entorp);
					$mapper->_bulkInsert($destination,$bulkData);
				} else {
					print "[TESTMODE] Skipping storage of gene and transcript coordinates\n";
				}
			}
		}
	}
	
	1;
}

my @TRANSKEYS = ('chromosome','chromosome_start','chromosome_end');

sub parseReactomeInteractions($$$$$) {
	my($payload,$left,$right,$pathway_id,$type)=@_;
	
	my($p_ENShash,$p_pathways,$p_foundInter)=@{$payload};
	
	$left = ''  unless(defined($left));
	$right= ''  unless(defined($right));
	foreach my $ensId (split(/\|/,$left),split(/\|/,$right)) {
		my $colon = index($ensId,':');
		if($colon != -1) {
			$ensId = substr($ensId,$colon+1);
			unless(exists($p_foundInter->{$pathway_id}{$ensId})) {
				$p_foundInter->{$pathway_id}{$ensId} = undef;
				
				$p_pathways->{$pathway_id} = {
					'pathway_id'	=> $pathway_id,
					'participants'	=> [],
				}  unless(exists($p_pathways->{$pathway_id}));
				
				my $participant = { 'participant_id' => $ensId };
				
				@{$participant}{@TRANSKEYS} = @{$p_ENShash->{$ensId}}{@TRANSKEYS}  if(exists($p_ENShash->{$ensId}));
				
				push(@{$p_pathways->{$pathway_id}{'participants'}},$participant);
			}
		}
	}
	
	1;
}

#####
# main
#####
my $testmode = undef;
if(scalar(@ARGV)>0 && $ARGV[0] eq '-t') {
	$testmode = 1;
	shift(@ARGV);
	print "* [TESTMODE] Enabled test mode (only validating data)\n";
}

if(scalar(@ARGV)>=2) {
	STDOUT->autoflush(1);
	STDERR->autoflush(1);
	my $iniFile = shift(@ARGV);
	# Defined outside
	my $cachingDir = shift(@ARGV);
	
	# First, let's read the configuration
	my $ini = Config::IniFiles->new(-file => $iniFile, -default => $BP::Loader::Mapper::DEFAULTSECTION);
	
	my $ensembl_ftp_base = undef;
	my $gencode_ftp_base = undef;
	my $reactome_http_base = undef;
	
	my $gencode_gtf_file = undef;
	my $reactome_bundle_file = undef;
	
	# Check the needed parameters for the construction
	if($ini->exists(DCC_LOADER_SECTION,ENSEMBL_FTP_BASE_TAG)) {
		$ensembl_ftp_base = $ini->val(DCC_LOADER_SECTION,ENSEMBL_FTP_BASE_TAG);
	} else {
		Carp::croak("Configuration file $iniFile must have '".ENSEMBL_FTP_BASE_TAG."'");
	}
	
	if($ini->exists(DCC_LOADER_SECTION,GENCODE_FTP_BASE_TAG)) {
		$gencode_ftp_base = $ini->val(DCC_LOADER_SECTION,GENCODE_FTP_BASE_TAG);
	} else {
		Carp::croak("Configuration file $iniFile must have '".GENCODE_FTP_BASE_TAG."'");
	}
	
	if($ini->exists(DCC_LOADER_SECTION,REACTOME_BASE_TAG)) {
		$reactome_http_base = URI->new($ini->val(DCC_LOADER_SECTION,REACTOME_BASE_TAG));
	} else {
		Carp::croak("Configuration file $iniFile must have '".REACTOME_BASE_TAG."'");
	}
	
	if($ini->exists(DCC_LOADER_SECTION,GENCODE_GTF_FILE_TAG)) {
		$gencode_gtf_file = $ini->val(DCC_LOADER_SECTION,GENCODE_GTF_FILE_TAG);
	} else {
		Carp::croak("Configuration file $iniFile must have '".GENCODE_GTF_FILE_TAG."'");
	}
	
	if($ini->exists(DCC_LOADER_SECTION,REACTOME_BUNDLE_TAG)) {
		$reactome_bundle_file = $ini->val(DCC_LOADER_SECTION,REACTOME_BUNDLE_TAG);
	} else {
		Carp::croak("Configuration file $iniFile must have '".REACTOME_BUNDLE_TAG."'");
	}
	
	Carp::croak('ERROR: undefined destination storage model')  unless($ini->exists($BP::Loader::Mapper::SECTION,'loaders'));
	
	# Zeroth, load the data model
	
	# Let's parse the model
	my $modelFile = $ini->val($BP::Loader::Mapper::SECTION,'model');
	# Setting up the right path on relative cases
	$modelFile = File::Spec->catfile(File::Basename::dirname($iniFile),$modelFile)  unless(File::Spec->file_name_is_absolute($modelFile));

	print "Parsing model $modelFile...\n";
	my $model = undef;
	eval {
		$model = BP::Model->new($modelFile);
	};
	
	if($@) {
		Carp::croak('ERROR: Model parsing and validation failed. Reason: '.$@);
	}
	print "\tDONE!\n";
	
	# Now, let's patch the properies of the different remote resources, using the properties inside the model
	my $ensembl_sql_file = ENSEMBL_SQL_FILE;
	eval {
		$model->annotations->applyAnnotations(\($ensembl_ftp_base,$gencode_ftp_base,$gencode_gtf_file,$reactome_bundle_file,$ensembl_sql_file));
	};
	
	if($@) {
		Carp::croak("$@ (does not exist in model $modelFile, used in $iniFile)");
	}
	
	# And translate these to URI objects
	$ensembl_ftp_base = URI->new($ensembl_ftp_base);
	$gencode_ftp_base = URI->new($gencode_ftp_base);
	
	# Setting up the loader storage model(s)
	my %storageModels = ();
	
	my $loadModelNames = $ini->val($BP::Loader::Mapper::SECTION,'loaders');
	
	my @loadModels = ();
	foreach my $loadModelName (split(/,/,$loadModelNames)) {
		unless(exists($storageModels{$loadModelName})) {
			$storageModels{$loadModelName} = BP::Loader::Mapper->newInstance($loadModelName,$model,$ini);
			push(@loadModels,$loadModelName);
		}
	}
	
	my $concept = $model->getConceptDomain('external')->conceptHash->{'gencode'};
	my $corrConcept = BP::Loader::CorrelatableConcept->new($concept);
	
	my @mappers = @storageModels{@loadModels};
	# Now, do we need to push the metadata there?
	if(!$ini->exists($BP::Loader::Mapper::SECTION,'metadata-loaders') || $ini->val($BP::Loader::Mapper::SECTION,'metadata-loaders') eq 'true') {
		foreach my $mapper (@mappers) {
			if($testmode) {
				print "\t [TESTMODE] Skipping storage of metadata model\n";
			} else {
				print "\t* Storing native model\n";
				$mapper->storeNativeModel();
			}
			
			$mapper->setDestination($corrConcept);
		}
	}
	
	# First, explicitly create the caching directory
	my $workingDir = BP::DCCLoader::WorkingDir->new($cachingDir);
	
	# Fetching HTTP resources
	print "Connecting to $reactome_http_base...\n";
	my $reactome_bundle_uri = $reactome_http_base->clone();
	$reactome_bundle_uri->path_segments($reactome_http_base->path_segments(),$reactome_bundle_file);
	
	my $reactome_bundle_local = $workingDir->mirror($reactome_bundle_uri);
	
	# Fetching FTP resources
	print "Connecting to $ensembl_ftp_base...\n";
	# Defined outside
	my $ftpServer = undef;
	
	my $ensemblHost = $ensembl_ftp_base->host();
	$ftpServer = Net::FTP::AutoReconnect->new($ensemblHost,Debug=>0) || Carp::croak("FTP connection to server ".$ensemblHost." failed: ".$@);
	$ftpServer->login(ANONYMOUS_USER,ANONYMOUS_PASS) || Carp::croak("FTP login to server $ensemblHost failed: ".$ftpServer->message());
	$ftpServer->binary();
	
	my $ensemblPath = $ensembl_ftp_base->path;
	
	my $localSQLFile = $workingDir->cachedGet($ftpServer,$ensemblPath.'/'.$ensembl_sql_file);
	my $localSeqRegion = $workingDir->cachedGet($ftpServer,$ensemblPath.'/'.ENSEMBL_SEQ_REGION_FILE);
	my $localGenes = $workingDir->cachedGet($ftpServer,$ensemblPath.'/'.ENSEMBL_GENE_FILE);
	my $localTranscripts = $workingDir->cachedGet($ftpServer,$ensemblPath.'/'.ENSEMBL_TRANSCRIPT_FILE);
	my $localXref = $workingDir->cachedGet($ftpServer,$ensemblPath.'/'.ENSEMBL_XREF_FILE);
	
	Carp::croak("FATAL ERROR: Unable to fetch files from $ensemblPath (host $ensemblHost)")  unless(defined($localSQLFile) && defined($localSeqRegion) && defined($localGenes) && defined($localTranscripts) && defined($localXref));
	
	$ftpServer->disconnect()  if($ftpServer->can('disconnect'));
	$ftpServer->quit()  if($ftpServer->can('quit'));
	$ftpServer = undef;
	
	print "Connecting to $gencode_ftp_base...\n";
	my $gencodeHost = $gencode_ftp_base->host();
	$ftpServer = Net::FTP::AutoReconnect->new($gencodeHost,Debug=>0) || Carp::croak("FTP connection to server ".$gencodeHost." failed: ".$@);
	$ftpServer->login(ANONYMOUS_USER,ANONYMOUS_PASS) || Carp::croak("FTP login to server $gencodeHost failed: ".$ftpServer->message());
	$ftpServer->binary();
	
	my $gencodePath = $gencode_ftp_base->path();
	
	my $localGTF = $workingDir->cachedGet($ftpServer,$gencodePath.'/'.$gencode_gtf_file);
	
	Carp::croak("FATAL ERROR: Unable to fetch files from $gencodePath (host $gencodeHost)")  unless(defined($localGTF));
		
	$ftpServer->disconnect()  if($ftpServer->can('disconnect'));
	$ftpServer->quit()  if($ftpServer->can('quit'));
	$ftpServer = undef;
	
	my $chroCV = $model->getNamedCV('EnsemblChromosomes');
	my $p_ENShash = BP::DCCLoader::Parsers::EnsemblGTParser::parseEnsemblGenesAndTranscripts($chroCV,$localSQLFile,$localSeqRegion,$localGenes,$localTranscripts,$localXref,$testmode);
	
	print "Parsing ",$localGTF,"\n";
	if(open(my $GTF,'-|',BP::Loader::Tools::GUNZIP,'-c',$localGTF)) {
		my %config = (
			TabParser::TAG_COMMENT	=>	'#',
			TabParser::TAG_CONTEXT	=> [$p_ENShash,\@mappers,$chroCV,$testmode],
			TabParser::TAG_CALLBACK => \&parseGTF,
		);
		$config{TabParser::TAG_VERBOSE} = 1  if($testmode);
		TabParser::parseTab($GTF,%config);
		
		close($GTF);
	} else {
		Carp::croak("ERROR: Unable to open EnsEMBL XREF file ".$localGTF);
	}
	
	# Storing the final genes and transcripts data
	foreach my $mapper (@mappers) {
		my $entorp = $mapper->validateAndEnactEntry(values(%{$p_ENShash}));
		unless($testmode) {
			my $destination = $mapper->getInternalDestination();
			my $bulkData = $mapper->_bulkPrepare($entorp);
			$mapper->_bulkInsert($destination,$bulkData);
		} else {
			print "[TESTMODE] Skipping storage of remaining gene and transcript coordinates\n";
		}
		$mapper->freeDestination();
	}
	
	# And now, the pathways!
	my $localReactomeInteractionsFile = File::Spec->catfile($cachingDir,REACTOME_INTERACTIONS_FILE);
	print "Parsing ",$localReactomeInteractionsFile,"\n";
	if(-f $localReactomeInteractionsFile || system('tar','xf',$reactome_bundle_local,'-C',$cachingDir,'--transform=s,^.*/,,','--wildcards','*/'.REACTOME_INTERACTIONS_FILE)==0) {
		if(open(my $REACT,'-|',BP::Loader::Tools::GUNZIP,'-c',$localReactomeInteractionsFile)) {
			my $reactomeConcept = $model->getConceptDomain('external')->conceptHash->{'reactome'};
			my $reactomeCorrConcept = BP::Loader::CorrelatableConcept->new($reactomeConcept);
			foreach my $mapper (@mappers) {
				$mapper->setDestination($reactomeCorrConcept);
			}
			
			my %pathways = ();
			my %foundInter = ();
			
			my %config = (
				TabParser::TAG_COMMENT	=>	'#',
				TabParser::TAG_CONTEXT	=> [$p_ENShash,\%pathways,\%foundInter],
				TabParser::TAG_CALLBACK => \&parseReactomeInteractions,
				#TabParser::TAG_ERR_CALLBACK => \&parseReactomeInteractions,
				TabParser::TAG_NUM_COLS	=> 9,	# We had to add it in order to avoid crap from Reactome generators
				TabParser::TAG_FOLLOW	=> 1,	# We had to add it in order to avoid crap from Reactome generators
				TabParser::TAG_FETCH_COLS => [1,4,7,6],
				TabParser::TAG_POS_FILTER => [[6 => 'reaction']],
			);
			$config{TabParser::TAG_VERBOSE} = 1  if($testmode);
			TabParser::parseTab($REACT,%config);
			
			close($REACT);
			
			%foundInter=();
			
			foreach my $mapper (@mappers) {
				my $entorp = $mapper->validateAndEnactEntry(values(%pathways));
				unless($testmode) {
					my $destination = $mapper->getInternalDestination();
					my $bulkData = $mapper->_bulkPrepare($entorp);
					$mapper->_bulkInsert($destination,$bulkData);
				} else {
					print "[TESTMODE] Skipping storage of pathways mappings\n";
				}
				$mapper->freeDestination();
			}
		} else {
			Carp::croak("ERROR: Unable to open Reactome interactions file ".$localReactomeInteractionsFile);
		}
	} elsif ($? == -1) {
		Carp::croak("failed to execute: $!");
	} elsif ($? & 127) {
		printf STDERR "child died with signal %d, %s coredump\n", ($? & 127),  ($? & 128) ? 'with' : 'without';
		exit 1;
	} else {
		printf STDERR "child exited with value %d\n", $? >> 8;
		exit 1;
	}
	
} else {
	print STDERR "Usage: $0 [-t] iniFile cachingDir\n"
}
