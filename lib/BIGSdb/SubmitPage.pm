#Written by Keith Jolley
#Copyright (c) 2015, University of Oxford
#E-mail: keith.jolley@zoo.ox.ac.uk
#
#This file is part of Bacterial Isolate Genome Sequence Database (BIGSdb).
#
#BIGSdb is free software: you can redistribute it and/or modify
#it under the terms of the GNU General Public License as published by
#the Free Software Foundation, either version 3 of the License, or
#(at your option) any later version.
#
#BIGSdb is distributed in the hope that it will be useful,
#but WITHOUT ANY WARRANTY; without even the implied warranty of
#MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#GNU General Public License for more details.
#
#You should have received a copy of the GNU General Public License
#along with BIGSdb.  If not, see <http://www.gnu.org/licenses/>.
package BIGSdb::SubmitPage;
use strict;
use warnings;
use 5.010;
use parent qw(BIGSdb::TreeViewPage);
use Error qw(:try);
use Log::Log4perl qw(get_logger);
my $logger = get_logger('BIGSdb.Page');
use BIGSdb::Utils;
use BIGSdb::Page 'SEQ_METHODS';
use constant COVERAGE    => qw(<20x 20-49x 50-99x +100x);
use constant READ_LENGTH => qw(<100 100-199 200-299 300-499 +500);
use constant ASSEMBLY    => ( 'de novo', 'mapped' );

sub get_javascript {
	my ($self) = @_;
	my $tree_js = $self->get_tree_javascript( { checkboxes => 1, check_schemes => 1 } );
	my $buffer = << "END";
\$(function () {
	\$("fieldset#scheme_fieldset").css("display","block");
	\$("#filter").click(function() {	
		var fields = ["technology", "assembly", "software", "read_length", "coverage", "locus", "fasta"];
		for (i=0; i<fields.length; i++){
			\$("#" + fields[i]).prop("required",false);
		}

	});	
	\$("#technology").change(function() {	
		check_technology();
	});
	check_technology();
});
function check_technology() {
	var fields = [ "read_length", "coverage"];
	for (i=0; i<fields.length; i++){
		if (\$("#technology").val() == 'Illumina'){			
			\$("#" + fields[i]).prop("required",true);
			\$("#" + fields[i] + "_label").text((fields[i]+":!").replace("_", " "));	
		} else {
			\$("#" + fields[i]).prop("required",false);
			\$("#" + fields[i] + "_label").text((fields[i]+":").replace("_", " "));
		}
	}	
}
$tree_js
END
	return $buffer;
}

sub initiate {
	my ($self) = @_;
	$self->{$_} = 1 foreach qw (jQuery jQuery.jstree noCache);
	return;
}

sub print_content {
	my ($self) = @_;
	my $q = $self->{'cgi'};
	say "<h1>Manage submissions</h1>";
	my $user_info = $self->{'datastore'}->get_user_info_from_username( $self->{'username'} );
	if ( !$user_info ) {
		say qq(<div class="box" id="queryform"><p>You are not a recognized user.  Submissions are disabled.</p></div>);
		return;
	}
	if ( $q->param('alleles') ) {
		if ( $q->param('submit') ) {
			$self->_update_allele_prefs;
		}
		$self->_submit_alleles;
		return;
	}
	say qq(<div class="box" id="resultstable"><div class="scrollable">);
	say qq(<h2>Submit new data</h2>);
	say qq(<p>Data submitted here will go in to a queue for handling by a curator or by an automated script.  You will be able to track )
	  . qq(the status of any submission.</p>);
	say qq(<ul><li><a href="$self->{'system'}->{'script_name'}?db=$self->{'instance'}&amp;page=submit&amp;alleles=1">Submit alleles</a>)
	  . qq(</li>);
	say qq(</ul>);
	my $pending = $self->{'datastore'}->run_query(
		"SELECT * FROM submissions WHERE (submitter,status)=(?,?)",
		[ $user_info->{'id'}, 'pending' ],
		{ fetch => 'all_arrayref', slice => {} }
	);
	if (@$pending) {
		say qq(<h2>Pending submissions</h2>);
	}
	say qq(</div></div>);
	return;
}

sub _submit_alleles {
	my ($self) = @_;
	my $q = $self->{'cgi'};
	if ( $q->param('submit') ) {
		my $ret = $self->_check_new_alleles;
		if ( $ret->{'err'} ) {
			my @err = @{ $ret->{'err'} };
			local $" = "<br />";
			my $plural = @err == 1 ? '' : 's';
			say qq(<div class="box" id="statusbad"><h2>Error$plural:</h2><p>@err</p></div>);
		} else {
			if ( $ret->{'info'} ) {
				my @info = @{ $ret->{'info'} };
				local $" = "<br />";
				my $plural = @info == 1 ? '' : 's';
				say qq(<div class="box" id="statuswarn"><h2>Warning$plural:</h2><p>@info</p><p>Warnings do not prevent submission )
				  . qq(but may result in the submission being rejected depending on curation criteria.</p></div>);
			}
			$self->_presubmit_alleles( $ret->{'seqs'} );
			return;
		}
	}
	say qq(<div class="box" id="queryform"><div class="scrollable">);
	say qq(<h2>Submit new alleles</h2>);
	say qq(<p>You need to make a separate submission for each locus for which you have new alleles - this is because different loci may )
	  . qq(have different curators.  You can submit any number of new sequences for a single locus as one submission. Sequences should be )
	  . qq(trimmed to the correct start/end sites for the selected locus.</p>);
	my $set_id = $self->get_set_id;
	my ( $loci, $labels );
	say $q->start_form;
	my $schemes =
	  $self->{'datastore'}->run_query( "SELECT id FROM schemes ORDER BY display_order,description", undef, { fetch => 'col_arrayref' } );

	if ( @$schemes > 1 ) {
		say qq(<fieldset id="scheme_fieldset" style="float:left;display:none"><legend>Filter loci by scheme</legend>);
		say qq(<div id="tree" class="scheme_tree" style="float:left;max-height:initial">);
		say $self->get_tree( undef, { no_link_out => 1, select_schemes => 1 } );
		say qq(</div>);
		say $q->submit( -name => 'filter', -id => 'filter', -label => 'Filter', -class => 'submit' );
		say qq(</fieldset>);
		say $q->hidden($_) foreach qw(db page alleles);
		my @selected_schemes;

		foreach ( @$schemes, 0 ) {
			push @selected_schemes, $_ if $q->param("s_$_");
		}
		my $scheme_loci = @selected_schemes ? $self->_get_scheme_loci( \@selected_schemes ) : undef;
		( $loci, $labels ) = $self->{'datastore'}->get_locus_list( { only_include => $scheme_loci, set_id => $set_id } );
	} else {
		( $loci, $labels ) = $self->{'datastore'}->get_locus_list( { set_id => $set_id } );
	}
	say qq(<fieldset style="float:left"><legend>Select locus</legend>);
	say $q->popup_menu( -name => 'locus', -id => 'locus', -values => $loci, -labels => $labels, -size => 9, -required => 'required' );
	say qq(</fieldset>);
	say qq(<fieldset style="float:left"><legend>Sequence details</legend>);
	say qq(<ul><li><label for="technology" class="parameter">technology:!</label>);
	my $att_labels = { '' => ' ' };    #Required for HTML5 validation
	say $q->popup_menu(
		-name     => 'technology',
		-id       => 'technology',
		-values   => [ '', SEQ_METHODS ],
		-labels   => $att_labels,
		-required => 'required',
		-default  => $self->{'prefs'}->{'submit_allele_technology'}
	);
	say qq(<li><label for="read_length" id="read_length_label" class="parameter">read length:</label>);
	say $q->popup_menu(
		-name    => 'read_length',
		-id      => 'read_length',
		-values  => [ '', READ_LENGTH ],
		-labels  => $att_labels,
		-default => $self->{'prefs'}->{'submit_allele_read_length'}
	);
	say qq(</li><li><label for="coverage" id="coverage_label" class="parameter">coverage:</label>);
	say $q->popup_menu(
		-name    => 'coverage',
		-id      => 'coverage',
		-values  => [ '', COVERAGE ],
		-labels  => $att_labels,
		-default => $self->{'prefs'}->{'submit_allele_coverage'}
	);
	say qq(</li><li><label for="assembly" class="parameter">assembly:!</label>);
	say $q->popup_menu(
		-name     => 'assembly',
		-id       => 'assembly',
		-values   => [ '', ASSEMBLY ],
		-labels   => $att_labels,
		-required => 'required',
		-default  => $self->{'prefs'}->{'submit_allele_assembly'}
	);
	say qq(</li><li><label for="software" class="parameter">assembly software:!</label>);
	say $q->textfield(
		-name     => 'software',
		-id       => 'software',
		-required => 'required',
		-default  => $self->{'prefs'}->{'submit_allele_software'}
	);
	say qq(</li><li><label for="comments" class="parameter">comments/notes:</label>);
	say $q->textarea( -name => 'comments', -id => 'comments' );
	say qq(</li></ul>);
	say qq(</fieldset>);
	say qq(<fieldset style="float:left"><legend>FASTA or single sequence</legend>);
	say $q->textarea( -name => 'fasta', -cols => 30, -rows => 5, -id => 'fasta', -required => 'required' );
	say qq(</fieldset>);
	say $q->hidden($_) foreach qw(db page alleles);
	$self->print_action_fieldset( { no_reset => 1 } );
	say $q->end_form;
	say qq(</div></div>);
	return;
}

sub _check_new_alleles {
	my ($self) = @_;
	my $q      = $self->{'cgi'};
	my $locus  = $q->param('locus');
	if ( !$locus ) {
		return { err => 'No locus is selected.' };
	}
	$locus =~ s/^cn_//;
	my $locus_info = $self->{'datastore'}->get_locus_info($locus);
	if ( !$locus_info ) {
		return { err => 'Locus $locus is not recognized.' };
	}
	my $seqs = {};
	if ( $q->param('fasta') ) {
		my $fasta_string = $q->param('fasta');
		$fasta_string = ">seq\n$fasta_string" if $fasta_string !~ /^\s*>/;
		return $self->{'datastore'}->check_new_alleles_fasta( $locus, \$fasta_string );
	}
	return;
}

sub _presubmit_alleles {
	my ( $self, $seqs ) = @_;
	return if ref $seqs ne 'ARRAY' || !@$seqs;
	my $q          = $self->{'cgi'};
	my $locus      = $q->param('locus');
	my $locus_info = $self->{'datastore'}->get_locus_info($locus);
	say qq(<div class="box" id="resultstable"><div class="scrollable">);
	my $plural = @$seqs == 1 ? '' : 's';
	say qq(<p>You have uploaded the following $locus sequence$plural:</p>);
	say qq(<table class="resultstable">);
	my $cds = $locus_info->{'data_type'} eq 'DNA' && $locus_info->{'complete_cds'} ? '<th>Complete CDS</th>' : '';
	say qq(<tr><th>Identifier</th><th>Length</th><th>Sequence</th>$cds</tr>);
	my $td = 1;

	foreach my $seq (@$seqs) {
		my $id       = $seq->id;
		my $length   = length $seq->seq;
		my $sequence = BIGSdb::Utils::truncate_seq( \$seq->seq, 40 );
		$cds = '';
		if ( $locus_info->{'data_type'} eq 'DNA' && $locus_info->{'complete_cds'} ) {
			$cds = BIGSdb::Utils::is_complete_cds( \$seq->seq )->{'cds'} ? '<td>yes</td>' : '<td>no</td>';
		}
		say qq(<tr class="td$td"><td>$id</td><td>$length</td><td class="seq">$sequence</td>$cds</tr>);
		$td = $td == 1 ? 2 : 1;
	}
	say qq(</table>);
	say qq(</div></div>);
	return;
}

sub _update_allele_prefs {
	my ($self) = @_;
	my $guid = $self->get_guid;
	return if !$guid;
	my $q = $self->{'cgi'};
	foreach my $param (qw(technology read_length coverage assembly software)) {
		my $field = "submit_allele_$param";
		my $value = $q->param($param);
		next if !$value;
		$self->{'prefstore'}->set_general( $guid, $self->{'system'}->{'db'}, $field, $value );
	}
	return;
}

sub _get_scheme_loci {
	my ( $self, $scheme_ids ) = @_;
	my @loci;
	my %locus_selected;
	my $set_id = $self->get_set_id;
	foreach (@$scheme_ids) {
		my $scheme_loci =
		  $_ ? $self->{'datastore'}->get_scheme_loci($_) : $self->{'datastore'}->get_loci_in_no_scheme( { set_id => $set_id } );
		foreach my $locus (@$scheme_loci) {
			if ( !$locus_selected{$locus} ) {
				push @loci, $locus;
				$locus_selected{$locus} = 1;
			}
		}
	}
	return \@loci;
}

sub set_pref_requirements {
	my ($self) = @_;
	$self->{'pref_requirements'} = { general => 1, main_display => 0, isolate_display => 0, analysis => 0, query_field => 0 };
	return;
}

sub get_title {
	my ($self) = @_;
	my $desc = $self->{'system'}->{'description'} || 'BIGSdb';
	return " Manage submissions - $desc ";
}
1;
