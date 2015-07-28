#!/usr/bin/perl

use warnings;
use strict;

use BP::DCCLoader::Parsers::MySQLSchemaParser;

use BP::Loader::Tools;

use TabParser;

package BP::DCCLoader::Parsers::EnsemblGTParser;

#####
# Method bodies
#####
sub parseSeqRegions($$$) {
	my($payload,$seq_region_id,$name) = @_;
	
	my($p_regionId,$chroCV) = @{$payload};
	
	my $term = $chroCV->getTerm($name);
	$p_regionId->{$seq_region_id} = $term->key()  if($term);
	
	1;
}

sub parseENS($$$$$$$$) {
	my($payload,$seq_region_id,$chromosome_start,$chromosome_end,$display_xref_id,$stable_id,$version,$description,$internal_id,$internal_gene_id)=@_;
	
	my($p_regionId,$p_ENShash,$p_ENSintHash,$p_geneMap,$chroCV) = @{$payload};
	
	if(exists($p_regionId->{$seq_region_id})) {
		my $fullStableId = $stable_id.'.'.$version;
		my @symbols = ($stable_id,$fullStableId);
		$description = undef  if($description eq "\\N");
		
		my $parsedData = undef;
		if(exists($p_ENShash->{$stable_id})) {
			$parsedData = $p_ENShash->{$stable_id};
			push(@{$parsedData->{'symbol'}},@symbols);
		} else {
			my $feature_cluster_id = defined($internal_gene_id)?$p_geneMap->{$internal_gene_id}->{'feature_cluster_id'}:$fullStableId;
			$parsedData = {
				#$fullStableId,
				'feature_cluster_id'	=> $feature_cluster_id,
				'chromosome'	=> $p_regionId->{$seq_region_id},
				'chromosome_start'	=> $chromosome_start,
				'chromosome_end'	=> $chromosome_end,
				'symbol'	=> \@symbols,
				'feature'	=> (defined($internal_gene_id)?'transcript':'gene')
			};
			$p_ENShash->{$stable_id} = $parsedData;
			$p_geneMap->{$internal_id} = $parsedData  unless(defined($internal_gene_id));
		}
		$parsedData->{'description'} = $description  if(defined($description));
		
		$p_ENSintHash->{$display_xref_id} = $parsedData;
	}
	
	1;
}

sub parseXREF($$$$$) {
	my($p_ENSintHash,$display_xref_id,$dbprimary_acc,$display_label,$description)=@_;
	
	if(exists($p_ENSintHash->{$display_xref_id})) {
		my $p_desc = $p_ENSintHash->{$display_xref_id}->{'symbol'};
		push(@{$p_desc},$dbprimary_acc);
		
		push(@{$p_desc},$display_label)  if($dbprimary_acc ne $display_label);
		push(@{$p_desc},$description)  unless($description eq "\\N");
	}
	
	1;
}

# parseEnsemblGenesAndTranscripts parameters:
#	chroCV: A BP::Model::CV instance. These are the known chromosomes
#	localSQLFile: path to the fetched Ensembl MySQL schema
#	localSeqRegion: path to the Ensembl MySQL dump of the region types
#	localGenes: path to the Ensembl MySQL dump of the known genes
#	localTranscripts: path to the Ensembl MySQL dump of the known transcripts
#	localXref: path to the Ensembl MySQL dump of the known cross-references
#	testmode:
# The returned hash reference holds the data to be dumped later
# The values will be array instances with the structure of
#	ensembl id (with version number)
#	chromosome (BLUEPRINT style)
#	chromosome_start (1-based)
#	chromosome_end (1-based)
#	symbols (an array)
#	feature
sub parseEnsemblGenesAndTranscripts($$$$$$;$) {
	my($chroCV,$localSQLFile,$localSeqRegion,$localGenes,$localTranscripts,$localXref,$testmode) = @_;
	
	# These are the Ensembl columns for its tables
	my $p_ensTables = BP::DCCLoader::Parsers::MySQLSchemaParser->new($localSQLFile);
	
	# These hashes will hold the data to be dumped later
	# The values will be array instances with the structure of
	#	ensembl id (with version number)
	#	chromosome (BLUEPRINT style)
	#	chromosome_start (1-based)
	#	chromosome_end (1-based)
	#	symbols (an array)
	#	feature
	my %ENShash = ();
	my %ENSintHash = ();
	
	# This hash holds the seq_region_id -> name correspondence
	my %regionId = ();
	
	print "Parsing ",$localSeqRegion,"\n";
	if(open(my $SEQREG,'-|',BP::Loader::Tools::GUNZIP,'-c',$localSeqRegion)) {
		my %config = (
			TabParser::TAG_CONTEXT	=> [\%regionId,$chroCV],
			TabParser::TAG_CALLBACK => \&parseSeqRegions,
			# The columns are 
			#	seq_region_id
			#	name
			TabParser::TAG_FETCH_COLS => $p_ensTables->mapTableColumns('seq_region',
				'seq_region_id',
				'name'
			), # [0,1],
		);
		$config{TabParser::TAG_VERBOSE} = 1  if($testmode);
		TabParser::parseTab($SEQREG,%config);
		
		close($SEQREG);
	} else {
		Carp::croak("ERROR: Unable to parse Sequence Regions file ".$localSeqRegion);
	}
	
	my %geneMap;
	
	print "Parsing ",$localGenes,"\n";
	if(open(my $ENSG,'-|',BP::Loader::Tools::GUNZIP,'-c',$localGenes)) {
		my %config = (
			TabParser::TAG_CONTEXT	=> [\%regionId,\%ENShash,\%ENSintHash,\%geneMap,$chroCV],
			TabParser::TAG_CALLBACK => \&parseENS,
			# The columns are 
			#	seq_region_id
			#	chromosome_start
			#	chromosome_end
			#	display_xref_id
			#	ensembl gene id
			#	ensembl gene id version
			#	description
			#	internal gene id
			TabParser::TAG_FETCH_COLS => $p_ensTables->mapTableColumns('gene',
				'seq_region_id',
				'seq_region_start',
				'seq_region_end',
				'display_xref_id',
				'stable_id',
				'version',
				'description',
				'gene_id'
			), # [3,4,5,7,14,15,10,0],
#			TabParser::TAG_NEG_FILTER => [[1 => 'LRG_gene']],
		);
		$config{TabParser::TAG_VERBOSE} = 1  if($testmode);
		TabParser::parseTab($ENSG,%config);
		
		close($ENSG);
	} else {
		Carp::croak("ERROR: Unable to parse EnsEMBL Genes file ".$localGenes);
	}
	
	print "Parsing ",$localTranscripts,"\n";
	if(open(my $ENST,'-|',BP::Loader::Tools::GUNZIP,'-c',$localTranscripts)) {
		my %config = (
			TabParser::TAG_CONTEXT	=> [\%regionId,\%ENShash,\%ENSintHash,\%geneMap,$chroCV],
			TabParser::TAG_CALLBACK => \&parseENS,
			# The columns are 
			#	seq_region_id
			#	chromosome_start
			#	chromosome_end
			#	display_xref_id
			#	ensembl transcript id
			#	ensembl transcript id version
			#	description
			#	internal transcript id
			#	internal gene id
			TabParser::TAG_FETCH_COLS => $p_ensTables->mapTableColumns('transcript',
				'seq_region_id',
				'seq_region_start',
				'seq_region_end',
				'display_xref_id',
				'stable_id',
				'version',
				'description',
				'transcript_id',
				'gene_id'
			), # [3,4,5,7,13,14,10,0,1],
#			TabParser::TAG_NEG_FILTER => [[8 => 'LRG_gene']],
		);
		$config{TabParser::TAG_VERBOSE} = 1  if($testmode);
		TabParser::parseTab($ENST,%config);
		
		close($ENST);
	} else {
		Carp::croak("ERROR: Unable to open EnsEMBL Transcripts file ".$localTranscripts);
	}
	
	# Freeing unused memory
	%regionId = ();
	%geneMap = ();
	
	print "Parsing ",$localXref,"\n";
	if(open(my $XREF,'-|',BP::Loader::Tools::GUNZIP,'-c',$localXref)) {
		my %config = (
			TabParser::TAG_CONTEXT	=> \%ENSintHash,
			TabParser::TAG_CALLBACK => \&parseXREF,
			TabParser::TAG_MULTILINE_SEP => "\\",
			# The columns are 
			#	display_xref_id
			#	dbprimary_acc
			#	display_label
			#	description
			TabParser::TAG_FETCH_COLS => $p_ensTables->mapTableColumns('xref',
				'xref_id',
				'dbprimary_acc',
				'display_label',
				'description'
			), # [0,2,3,5],
		);
		$config{TabParser::TAG_VERBOSE} = 1  if($testmode);
		TabParser::parseTab($XREF,%config);
		
		close($XREF);
	} else {
		Carp::croak("ERROR: Unable to open EnsEMBL XREF file ".$localXref);
	}
	# Freeing unused memory
	%ENSintHash = ();
	
	return \%ENShash;
}

1;
