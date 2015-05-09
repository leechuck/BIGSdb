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
use BIGSdb::BIGSException;
use BIGSdb::Page 'SEQ_METHODS';
use List::MoreUtils qw(none);
use File::Path qw(make_path remove_tree);
use POSIX;
use constant COVERAGE        => qw(<20x 20-49x 50-99x >100x);
use constant READ_LENGTH     => qw(<100 100-199 200-299 300-499 >500);
use constant ASSEMBLY        => ( 'de novo', 'mapped' );
use constant MAX_UPLOAD_SIZE => 32 * 1024 * 1024;                        #32Mb

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
	my ($self)        = @_;
	my $q             = $self->{'cgi'};
	my $submission_id = $q->param('submission_id');
	if ( $q->param('tar') && $q->param('submission_id') ) {
		$self->{'type'}       = 'tar';
		$self->{'attachment'} = "$submission_id\.tar";
		$self->{'noCache'}    = 1;
		return;
	}
	$self->{$_} = 1 foreach qw (jQuery jQuery.jstree noCache);
	return;
}

sub print_content {
	my ($self) = @_;
	my $q = $self->{'cgi'};
	if ( $q->param('abort') && $q->param('submission_id') && $q->param('confirm') ) {
		$self->_abort_submission( $q->param('submission_id') );
	} elsif ( $q->param('finalize') ) {
		$self->_finalize_submission( $q->param('submission_id') );
	} elsif ( $q->param('tar') ) {
		$self->_tar_archive( $q->param('submission_id') );
		return;
	} elsif ( $q->param('view') ) {
		$self->_view_submission( $q->param('submission_id') );
		return;
	} elsif ( $q->param('curate') ) {
		$self->_curate_submission( $q->param('submission_id') );
		return;
	}
	say q(<h1>Manage submissions</h1>);
	my $user_info = $self->{'datastore'}->get_user_info_from_username( $self->{'username'} );
	if ( !$user_info ) {
		say q(<div class="box" id="statusbad"><p>You are not a recognized user.  Submissions are disabled.</p></div>);
		return;
	}
	if ( $q->param('alleles') ) {
		if ( $self->{'system'}->{'dbtype'} ne 'sequences' ) {
			say q(<div class="box" id="statusbad"><p>You cannot submit new allele sequences for definition in an isolate )
			  . q(database.<p></div>);
			return;
		}
		if ( $q->param('submit') ) {
			$self->_update_allele_prefs;
		}
		$self->_submit_alleles;
		return;
	}
	say q(<div class="box" id="resultstable"><div class="scrollable">);
	if ( !$self->_print_started_submissions ) {    #Returns true if submissions in process
		say q(<h2>Submit new data</h2>);
		say q(<p>Data submitted here will go in to a queue for handling by a curator or by an automated script.  You will be able to )
		  . q(track the status of any submission.</p>);
		say qq(<ul><li><a href="$self->{'system'}->{'script_name'}?db=$self->{'instance'}&amp;page=submit&amp;alleles=1">Submit alleles</a>)
		  . q(</li></ul>);
	}
	$self->_print_pending_submissions_table;
	$self->_print_submissions_for_curation;
	say q(</div></div>);
	return;
}

sub _get_submissions_by_status {
	my ( $self, $status, $options ) = @_;
	$options = {} if ref $options ne 'HASH';
	my $user_info = $self->{'datastore'}->get_user_info_from_username( $self->{'username'} );
	my ( $qry, $get_all, @args );
	if ( $options->{'get_all'} ) {
		$qry     = 'SELECT * FROM submissions WHERE status=? ORDER BY datestamp asc';
		$get_all = 1;
		push @args, $status;
	} else {
		$qry     = 'SELECT * FROM submissions WHERE (submitter,status)=(?,?) ORDER BY datestamp asc';
		$get_all = 0;
		push @args, ( $user_info->{'id'}, $status );
	}
	my $submissions =
	  $self->{'datastore'}
	  ->run_query( $qry, \@args, { fetch => 'all_arrayref', slice => {}, cache => "SubmitPage::get_submissions_by_status$get_all" } );
	return $submissions;
}

sub _print_started_submissions {
	my ($self) = @_;
	my $incomplete = $self->_get_submissions_by_status('started');
	if (@$incomplete) {
		say qq(<h2>Submission in process</h2>);
		say qq(<p>Please note that you must either proceed with or abort the in process submission before you can start another.</p>);
		foreach my $submission (@$incomplete) {    #There should only be one but this isn't enforced at the database level.
			say qq(<dl class="data"><dt>Submission</dt><dd>$submission->{'id'}</dd>);
			say qq(<dt>Datestamp</dt><dd>$submission->{'datestamp'}</dd>);
			say qq(<dt>Type</dt><dd>$submission->{'type'}</dd>);
			if ( $submission->{'type'} eq 'alleles' ) {
				my $allele_submission = $self->get_allele_submission( $submission->{'id'} );
				if ($allele_submission) {
					say qq(<dt>Locus</dt><dd>$allele_submission->{'locus'}</dd>);
					my $seq_count = @{ $allele_submission->{'seqs'} };
					say qq(<dt>Sequences</dt><dd>$seq_count</dd>);
				}
				say qq(<dt>Action</dt><dd><a href="$self->{'system'}->{'script_name'}?db=$self->{'instance'}&amp;page=submit&amp;)
				  . qq($submission->{'type'}=1&amp;abort=1&amp;no_check=1">Abort</a> | )
				  . qq(<a href="$self->{'system'}->{'script_name'}?db=$self->{'instance'}&amp;page=submit&amp;$submission->{'type'}=1&amp;)
				  . qq(continue=1">Continue</a>);
			}
			say qq(</dl>);
		}
		return 1;
	}
	return;
}

sub _print_pending_submissions_table {
	my ($self) = @_;
	my $pending = $self->_get_submissions_by_status('pending');
	if (@$pending) {
		say qq(<h2>Pending submissions</h2>);
		say qq(<p>You have submitted the following submissions that are pending curation:</p>);
		say qq(<table class="resultstable"><tr><th>Submission id</th><th>Datestamp</th><th>Type</th><th>Details</th></tr>);
		my $td = 1;
		foreach my $submission (@$pending) {
			my $url = qq($self->{'system'}->{'script_name'}?db=$self->{'instance'}&amp;page=submit&amp;)
			  . qq(submission_id=$submission->{'id'}&amp;view=1);
			say qq(<tr class="td$td"><td><a href="$url">$submission->{'id'}</a></td>);
			say qq(<td>$submission->{'datestamp'}</td><td>$submission->{'type'}</td>);
			my $details = '';
			if ( $submission->{'type'} eq 'alleles' ) {
				my $allele_submission = $self->get_allele_submission( $submission->{'id'} );
				my $allele_count      = @{ $allele_submission->{'seqs'} };
				my $plural            = $allele_count == 1 ? '' : 's';
				$details = "$allele_count $allele_submission->{'locus'} sequence$plural";
			}
			say qq(<td>$details</td></tr>);
			$td = $td == 1 ? 2 : 1;
		}
		say qq(</table>);
	}
	return;
}

sub _print_submissions_for_curation {
	my ($self) = @_;
	my $user_info = $self->{'datastore'}->get_user_info_from_username( $self->{'username'} );
	return if !$user_info || ( $user_info->{'status'} ne 'admin' && $user_info->{'status'} ne 'curator' );
	if ( $self->{'system'}->{'dbtype'} eq 'sequences' ) {
		$self->_print_allele_submissions_for_curation;
	}
	return;
}

sub _print_allele_submissions_for_curation {
	my ($self) = @_;
	my $user_info = $self->{'datastore'}->get_user_info_from_username( $self->{'username'} );
	my $submissions = $self->_get_submissions_by_status( 'pending', { get_all => 1 } );
	my $buffer;
	my $td = 1;
	foreach my $submission (@$submissions) {
		next if $submission->{'type'} ne 'alleles';
		my $allele_submission = $self->get_allele_submission( $submission->{'id'} );
		next
		  if !($self->is_admin
			|| $self->{'datastore'}->is_allowed_to_modify_locus_sequences( $allele_submission->{'locus'}, $user_info->{'id'} ) );
		my $submitter_string = $self->{'datastore'}->get_user_string( $submission->{'submitter'}, { email => 1 } );
		my $row =
		    qq(<tr class="td$td"><td><a href="$self->{'system'}->{'script_name'}?db=$self->{'instance'}&amp;page=submit&amp;)
		  . qq(submission_id=$submission->{'id'}&amp;curate=1">$submission->{'id'}</a></td><td>$submission->{'datestamp'}</td>)
		  . qq(<td>$submitter_string</td><td>$allele_submission->{'locus'}</td>);
		my $seq_count = @{ $allele_submission->{'seqs'} };
		$row .= qq(<td>$seq_count</td></tr>\n);
		$td = $td == 1 ? 2 : 1;
		$buffer .= $row;
	}
	if ($buffer) {
		say qq(<h2>New allele sequence submissions waiting for curation</h2>);
		say qq(<p>You account is authorized to handle the following submissions:<p>);
		say qq(<table class="resultstable"><tr><th>Submission id</th><th>Datestamp</th><th>Submitter</th><th>Locus</th>)
		  . qq(<th>Sequences</th></tr>);
		say $buffer;
		say qq(</table>);
	}
	return;
}

sub _print_allele_warnings {
	my ( $self, $warnings ) = @_;
	return if ref $warnings ne 'ARRAY' || !@$warnings;
	my @info = @$warnings;
	local $" = "<br />";
	my $plural = @info == 1 ? '' : 's';
	say qq(<div class="box" id="statuswarn"><h2>Warning$plural:</h2><p>@info</p><p>Warnings do not prevent submission )
	  . qq(but may result in the submission being rejected depending on curation criteria.</p></div>);
	return;
}

sub _abort_submission {
	my ( $self, $submission_id ) = @_;
	my $user_info = $self->{'datastore'}->get_user_info_from_username( $self->{'username'} );
	eval { $self->{'db'}->do( "DELETE FROM submissions WHERE (id,submitter)=(?,?)", undef, $submission_id, $user_info->{'id'} ) };
	if ($@) {
		$logger->error($@);
		$self->{'db'}->rollback;
	} else {
		$self->{'db'}->commit;
		$self->_delete_submission_files($submission_id);
	}
	return;
}

sub _delete_submission_files {
	my ( $self, $submission_id ) = @_;
	my $dir = $self->_get_submission_dir($submission_id);
	remove_tree $1 if $dir =~ /^($self->{'config'}->{'submission_dir'}\/BIGSdb[^\/]+$)/;
	return;
}

sub _finalize_submission {
	my ( $self, $submission_id ) = @_;
	my $q = $self->{'cgi'};
	my $type = $self->{'datastore'}->run_query( "SELECT type FROM submissions WHERE id=?", $submission_id );
	return if !$type;
	my $user_info = $self->{'datastore'}->get_user_info_from_username( $self->{'username'} );
	eval {
		if ( $type eq 'alleles' )
		{
			$self->{'db'}->do(
				"UPDATE allele_submissions SET (technology,read_length,coverage,assembly,software)=(?,?,?,?,?) "
				  . "WHERE submission_id=? AND submission_id IN (SELECT id FROM submissions WHERE submitter=?)",
				undef,
				$q->param('technology'),
				$q->param('read_length'),
				$q->param('coverage'),
				$q->param('assembly'),
				$q->param('software'),
				$submission_id,
				$user_info->{'id'}
			);
		}
		$self->{'db'}
		  ->do( "UPDATE submissions SET status='pending' WHERE (id,submitter)=(?,?)", undef, $submission_id, $user_info->{'id'} );
	};
	if ($@) {
		$logger->error($@);
		$self->{'db'}->rollback;
	} else {
		$self->{'db'}->commit;
	}
	return;
}

sub _submit_alleles {
	my ($self)        = @_;
	my $q             = $self->{'cgi'};
	my $submission_id = $self->_get_started_submission;
	$q->param( submission_id => $submission_id );
	my $ret;
	if ($submission_id) {
		my $allele_submission = $self->get_allele_submission($submission_id);
		my $fasta_string;
		foreach my $seq ( @{ $allele_submission->{'seqs'} } ) {
			$fasta_string .= ">$seq->{'seq_id'}\n";
			$fasta_string .= "$seq->{'sequence'}\n";
		}
		if ( !$q->param('no_check') ) {
			$ret = $self->{'datastore'}->check_new_alleles_fasta( $allele_submission->{'locus'}, \$fasta_string );
			$self->_print_allele_warnings( $ret->{'info'} );
		}
		$self->_presubmit_alleles( $submission_id, undef );
		return;
	} elsif ( $q->param('submit') || $q->param('continue') || $q->param('abort') ) {
		$ret = $self->_check_new_alleles;
		if ( $ret->{'err'} ) {
			my @err = @{ $ret->{'err'} };
			local $" = '<br />';
			my $plural = @err == 1 ? '' : 's';
			say qq(<div class="box" id="statusbad"><h2>Error$plural:</h2><p>@err</p></div>);
		} else {
			if ( $ret->{'info'} ) {
				$self->_print_allele_warnings( $ret->{'info'} );
			}
			$self->_presubmit_alleles( undef, $ret->{'seqs'} );
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
	$self->_print_sequence_details_fieldset($submission_id);
	say qq(<fieldset style="float:left"><legend>FASTA or single sequence</legend>);
	say $q->textarea( -name => 'fasta', -cols => 30, -rows => 5, -id => 'fasta', -required => 'required' );
	say qq(</fieldset>);
	say $q->hidden($_) foreach qw(db page alleles);
	$self->print_action_fieldset( { no_reset => 1 } );
	say $q->end_form;
	say qq(</div></div>);
	return;
}

sub _print_sequence_details_fieldset {
	my ( $self, $submission_id ) = @_;
	my $q = $self->{'cgi'};
	say qq(<fieldset style="float:left"><legend>Sequence details</legend>);
	say qq(<ul><li><label for="technology" class="parameter">technology:!</label>);
	my $allele_submission = $submission_id ? $self->get_allele_submission($submission_id) : undef;
	my $att_labels = { '' => ' ' };    #Required for HTML5 validation
	say $q->popup_menu(
		-name     => 'technology',
		-id       => 'technology',
		-values   => [ '', SEQ_METHODS ],
		-labels   => $att_labels,
		-required => 'required',
		-default  => $allele_submission->{'technology'} // $self->{'prefs'}->{'submit_allele_technology'}
	);
	say qq(<li><label for="read_length" id="read_length_label" class="parameter">read length:</label>);
	say $q->popup_menu(
		-name    => 'read_length',
		-id      => 'read_length',
		-values  => [ '', READ_LENGTH ],
		-labels  => $att_labels,
		-default => $allele_submission->{'read_length'} // $self->{'prefs'}->{'submit_allele_read_length'}
	);
	say qq(</li><li><label for="coverage" id="coverage_label" class="parameter">coverage:</label>);
	say $q->popup_menu(
		-name    => 'coverage',
		-id      => 'coverage',
		-values  => [ '', COVERAGE ],
		-labels  => $att_labels,
		-default => $allele_submission->{'coverage'} // $self->{'prefs'}->{'submit_allele_coverage'}
	);
	say qq(</li><li><label for="assembly" class="parameter">assembly:!</label>);
	say $q->popup_menu(
		-name     => 'assembly',
		-id       => 'assembly',
		-values   => [ '', ASSEMBLY ],
		-labels   => $att_labels,
		-required => 'required',
		-default  => $allele_submission->{'assembly'} // $self->{'prefs'}->{'submit_allele_assembly'}
	);
	say qq(</li><li><label for="software" class="parameter">assembly software:!</label>);
	say $q->textfield(
		-name     => 'software',
		-id       => 'software',
		-required => 'required',
		-default  => $allele_submission->{'software'} // $self->{'prefs'}->{'submit_allele_software'}
	);
	say q(</li></ul>);
	say q(</fieldset>);
	return;
}

sub _check_new_alleles {
	my ($self) = @_;
	my $q      = $self->{'cgi'};
	my $locus  = $q->param('locus');
	if ( !$locus ) {
		return { err => ['No locus is selected.'] };
	}
	$locus =~ s/^cn_//;
	$q->param( locus => $locus );
	my $locus_info = $self->{'datastore'}->get_locus_info($locus);
	if ( !$locus_info ) {
		return { err => ['Locus $locus is not recognized.'] };
	}
	if ( $q->param('fasta') ) {
		my $fasta_string = $q->param('fasta');
		$fasta_string = ">seq\n$fasta_string" if $fasta_string !~ /^\s*>/;
		return $self->{'datastore'}->check_new_alleles_fasta( $locus, \$fasta_string );
	}
	return;
}

sub _start_submission {
	my ( $self, $type ) = @_;
	$logger->logdie("Invalid submission type '$type'") if none { $type eq $_ } qw (alleles);
	my $submission_id = 'BIGSdb_' . strftime( "%Y%m%d%H%M%S", localtime ) . "_$$\_" . int( rand(99999) );
	my $user_info = $self->{'datastore'}->get_user_info_from_username( $self->{'username'} );
	eval {
		$self->{'db'}->do( "INSERT INTO submissions (id,type,submitter,datestamp,status) VALUES (?,?,?,?,?)",
			undef, $submission_id, $type, $user_info->{'id'}, 'now', 'started' );
	};
	if ($@) {
		$logger->error($@);
		$self->{'db'}->rollback;
	} else {
		$self->{'db'}->commit;
	}
	return $submission_id;
}

sub _get_started_submission {
	my ($self) = @_;
	my $user_info = $self->{'datastore'}->get_user_info_from_username( $self->{'username'} );
	return $self->{'datastore'}->run_query(
		"SELECT id FROM submissions WHERE (submitter,status)=(?,?)",
		[ $user_info->{'id'}, 'started' ],
		{ cache => 'SubmitPage::get_started_submission' }
	);
}

sub _get_submission {
	my ( $self, $submission_id ) = @_;
	$logger->logcarp("No submission_id passed") if !$submission_id;
	return $self->{'datastore'}->run_query( "SELECT * FROM submissions WHERE id=?",
		$submission_id, { fetch => 'row_hashref', cache => 'SubmitPage::get_submission' } );
}

sub get_allele_submission {
	my ( $self, $submission_id ) = @_;
	$logger->logcarp('No submission_id passed') if !$submission_id;
	my $submission = $self->{'datastore'}->run_query( "SELECT * FROM allele_submissions WHERE submission_id=?",
		$submission_id, { fetch => 'row_hashref', cache => 'SubmitPage::get_allele_submission' } );
	return if !$submission;
	my $seq_data = $self->{'datastore'}->run_query( "SELECT * FROM allele_submission_sequences WHERE submission_id=? ORDER BY seq_id",
		$submission_id, { fetch => 'all_arrayref', slice => {} } );
	$submission->{'seqs'} = $seq_data;
	return $submission;
}

sub _presubmit_alleles {
	my ( $self, $submission_id, $seqs ) = @_;
	$seqs //= [];
	return if !$submission_id && !@$seqs;
	my $q = $self->{'cgi'};
	my $locus;
	if ($submission_id) {
		my $allele_submission = $self->get_allele_submission($submission_id);
		$locus = $allele_submission->{'locus'} // '';
		$seqs  = $allele_submission->{'seqs'}  // [];
	} else {
		$locus         = $q->param('locus');
		$submission_id = $self->_start_submission('alleles');
		eval {
			$self->{'db'}->do(
				'INSERT INTO allele_submissions (submission_id,locus,technology,read_length,coverage,assembly,'
				  . 'software) VALUES (?,?,?,?,?,?,?)',
				undef,
				$submission_id,
				$locus,
				$q->param('technology'),
				$q->param('read_length'),
				$q->param('coverage'),
				$q->param('assembly'),
				$q->param('software'),
			);
		};
		if ($@) {
			$logger->error($@);
			$self->{'db'}->rollback;
			return;
		}
		if (@$seqs) {
			my $insert_sql =
			  $self->{'db'}->prepare('INSERT INTO allele_submission_sequences (submission_id,seq_id,sequence,status) VALUES (?,?,?,?)');
			foreach my $seq (@$seqs) {
				eval { $insert_sql->execute( $submission_id, $seq->{'seq_id'}, $seq->{'sequence'}, 'pending' ) };
				if ($@) {
					$logger->error($@);
					$self->{'db'}->rollback;
					return;
				}
			}
			$self->_write_allele_FASTA($submission_id);
		}
		$self->{'db'}->commit;
	}
	if ( $q->param('file_upload') ) {
		my $upload_file = $self->_upload_files($submission_id);
	}
	if ( $q->param('delete') ) {
		my $files = $self->_get_submission_files($submission_id);
		my $i     = 0;
		my $dir   = $self->_get_submission_dir($submission_id) . '/supporting_files';
		foreach my $file (@$files) {
			if ( $q->param("file$i") ) {
				if ( $file->{'filename'} =~ /^([^\/]+)$/ ) {
					my $filename = $1;
					unlink "$dir/$filename" || $logger->error("Cannot delete $dir/$filename.");
				}
				$q->delete("file$i");
			}
			$i++;
		}
	}
	say q(<div class="box" id="resultstable"><div class="scrollable">);
	if ( $q->param('abort') ) {
		say q(<div style="float:left">);
		$self->print_warning_sign( { no_div => 1 } );
		say q(</div>);
		say $q->start_form;
		$self->print_action_fieldset( { no_reset => 1, submit_label => 'Abort submission!' } );
		$q->param( confirm       => 1 );
		$q->param( submission_id => $submission_id );
		say $q->hidden($_) foreach qw(db page submission_id abort confirm);
		say $q->end_form;
	}
	say qq(<h2>Submission: $submission_id</h2>);
	say $q->start_form;
	$self->_print_sequence_details_fieldset($submission_id);
	$self->_print_sequence_table_fieldset( $submission_id, { download_link => 1 } );
	$self->print_action_fieldset( { no_reset => 1, submit_label => 'Finalize submission!' } );
	$q->param( finalize      => 1 );
	$q->param( submission_id => $submission_id );
	say $q->hidden($_) foreach qw(db page locus submit finalize submission_id);
	say $q->end_form;
	say q(<fieldset style="float:left"><legend>Supporting files</legend>);
	say q(<p>Please upload any supporting files required for curation.  Ensure that these are named unambiguously or add an explanatory )
	  . q(note so that they can be linked to the appropriate sequence.  Individual filesize is limited to )
	  . BIGSdb::Utils::get_nice_size(MAX_UPLOAD_SIZE)
	  . q(.</p>);
	say $q->start_form;
	print $q->filefield( -name => 'file_upload', -id => 'file_upload', -multiple );
	say $q->submit( -name => 'Upload files', -class => 'submitbutton ui-button ui-widget ui-state-default ui-corner-all' );
	$q->param( no_check => 1 );
	say $q->hidden($_) foreach qw(db page alleles locus submit submission_id no_check);
	say $q->end_form;
	my $files = $self->_get_submission_files($submission_id);

	if (@$files) {
		say $q->start_form;
		$self->_print_submission_file_table( $submission_id, { delete_checkbox => 1 } );
		$q->param( delete => 1 );
		say $q->hidden($_) foreach qw(db page alleles delete no_check);
		say $q->submit( -label => 'Delete selected files', -class => 'submitbutton ui-button ui-widget ui-state-default ui-corner-all' );
		say $q->end_form;
	}
	say qq(</fieldset>);
	$self->_print_message_fieldset($submission_id);
	say qq(</div></div>);
	return;
}

sub _print_sequence_table_fieldset {
	my ( $self, $submission_id, $options ) = @_;
	$options = {} if ref $options ne 'HASH';
	my $q          = $self->{'cgi'};
	my $submission = $self->_get_submission($submission_id);
	return if !$submission;
	return if $submission->{'type'} ne 'alleles';
	my $allele_submission = $self->get_allele_submission($submission_id);
	return if !$allele_submission;
	my $seqs = $allele_submission->{'seqs'};

	if ( $q->param('curate') ) {
		if ( $q->param('update') ) {
			foreach my $seq (@$seqs) {
				my $status = $q->param("status_$seq->{'seq_id'}");
				next if !defined $status;
				eval {
					$self->{'db'}->do( 'UPDATE allele_submission_sequences SET status=? WHERE (submission_id,seq_id)=(?,?)',
						undef, $status, $submission_id, $seq->{'seq_id'} );
				};
				if ($@) {
					$logger->error($@);
					$self->{'db'}->rollback;
				} else {
					$self->{'db'}->commit;
				}
			}
			$allele_submission = $self->get_allele_submission($submission_id);
			$seqs              = $allele_submission->{'seqs'};
		}
	}
	my $locus      = $allele_submission->{'locus'};
	my $locus_info = $self->{'datastore'}->get_locus_info($locus);
	say qq(<fieldset style="float:left"><legend>Sequences</legend>);
	my $fasta_icon = $self->get_file_icon('FAS');
	my $plural = @$seqs == 1 ? '' : 's';
	say qq(<p>You are submitting the following $allele_submission->{'locus'} sequence$plural: )
	  . qq(<a href="/submissions/$submission_id/sequences.fas">Download$fasta_icon</a></p>)
	  if ( $options->{'download_link'} );
	say $q->start_form;
	say qq(<table class="resultstable">);
	my $cds = $locus_info->{'data_type'} eq 'DNA' && $locus_info->{'complete_cds'} ? '<th>Complete CDS</th>' : '';
	say qq(<tr><th>Identifier</th><th>Length</th><th>Sequence</th>$cds<th>Status</th><th>Assigned allele</th></tr>);
	my $all_assigned_or_rejected = 1;
	my $all_assigned             = 1;
	my $td                       = 1;
	my $pending_seqs             = [];

	foreach my $seq (@$seqs) {
		my $id       = $seq->{'seq_id'};
		my $length   = length $seq->{'sequence'};
		my $sequence = BIGSdb::Utils::truncate_seq( \$seq->{'sequence'}, 40 );
		$cds = '';
		if ( $locus_info->{'data_type'} eq 'DNA' && $locus_info->{'complete_cds'} ) {
			$cds =
			  BIGSdb::Utils::is_complete_cds( \$seq->{'sequence'} )->{'cds'}
			  ? '<td><span class="fa fa-check fa-lg" style="color:green"></span></td>'
			  : '<td><span class="fa fa-times fa-lg" style="color:red"></span></td>';
		}
		say qq(<tr class="td$td"><td>$id</td><td>$length</td>);
		say qq(<td class="seq">$sequence</td>$cds);
		my $assigned = $self->{'datastore'}->run_query(
			"SELECT allele_id FROM sequences WHERE (locus,sequence)=(?,?)",
			[ $allele_submission->{'locus'}, $seq->{'sequence'} ],
			{ cache => 'SubmitPage::print_sequence_table_fieldset' }
		);
		if ( !defined $assigned && defined $seq->{'assigned_id'} ) {
			$self->_clear_assigned_id( $submission_id, $seq->{'seq_id'} );
		}
		if ( !defined $assigned && $seq->{'status'} eq 'assigned' ) {
			$self->_set_allele_status( $submission_id, $seq->{'seq_id'}, 'pending' );
		}
		push @$pending_seqs, $seq if !defined $assigned && $seq->{'status'} ne 'rejected';
		$assigned //= '';
		if ( $options->{'curate'} ) {
			if ($assigned) {
				say qq(<td>$seq->{'status'}</td>);
			} else {
				say q(<td>);
				say $q->popup_menu( -name => "status_$seq->{'seq_id'}", -values => [qw(pending rejected)], -default => $seq->{'status'} );
				say q(</td>);
				$all_assigned_or_rejected = 0 if $seq->{'status'} ne 'rejected';
				$all_assigned = 0;
			}
		} else {
			say qq(<td>$seq->{'status'}</td>);
		}
		if ( $options->{'curate'} && $seq->{'status'} ne 'rejected' && $assigned eq '' ) {
			say qq(<td><a href="$self->{'system'}->{'curate_script'}?db=$self->{'instance'}&amp;page=add&amp;table=sequences&amp;)
			  . qq(locus=$locus&amp;submission_id=$submission_id&seq_id=$seq->{'seq_id'}&amp;sender=$submission->{'submitter'}">)
			  . qq(<span class="fa fa-lg fa-edit"></span>Curate</a></td>);
		} else {
			say qq(<td>$assigned</td>);
		}
		say q(</tr>);
		$td = $td == 1 ? 2 : 1;
	}
	say qq(</table>);
	if ( $options->{'curate'} && !$all_assigned ) {
		say q(<div style="float:right">);
		say $q->submit( -name => 'update', -label => 'Update',
			-class => 'submitbutton ui-button ui-widget ui-state-default ui-corner-all' );
		say q(</div>);
	}
	say $q->hidden($_) foreach qw(db page submission_id curate);
	say $q->end_form;
	if ( $options->{'curate'} && !$all_assigned_or_rejected ) {
		say $q->start_form( -action => $self->{'system'}->{'curate_script'} );
		say $q->submit( -name => 'Batch curate', -class => 'submitbutton ui-button ui-widget ui-state-default ui-corner-all' );
		my $page = $q->param('page');
		$q->param( page         => 'batchAddFasta' );
		$q->param( locus        => $locus );
		$q->param( sender       => $submission->{'submitter'} );
		$q->param( sequence     => $self->_get_fasta_string($pending_seqs) );
		$q->param( complete_CDS => $locus_info->{'complete_cds'} ? 'on' : 'off' );
		say $q->hidden($_) foreach qw( db page submission_id locus sender sequence complete_CDS);
		say $q->end_form;
		$q->param( page => $page );    #Restore value
	}
	say qq(</fieldset>);
	$self->{'all_assigned_or_rejected'} = $all_assigned_or_rejected;
	return;
}

sub _clear_assigned_id {
	my ( $self, $submission_id, $seq_id ) = @_;
	eval {
		$self->{'db'}->do( 'UPDATE allele_submission_sequences SET assigned_id=NULL WHERE (submission_id,seq_id)=(?,?)',
			undef, $submission_id, $seq_id );
	};
	if ($@) {
		$logger->error($@);
		$self->{'db'}->rollback;
	} else {
		$self->{'db'}->commit;
	}
	return;
}

sub _set_allele_status {
	my ( $self, $submission_id, $seq_id, $status ) = @_;
	eval {
		$self->{'db'}->do( 'UPDATE allele_submission_sequences SET status=? WHERE (submission_id,seq_id)=(?,?)',
			undef, $status, $submission_id, $seq_id )
	};
	if ($@) {
		$logger->error($@);
		$self->{'db'}->rollback;
	} else {
		$self->{'db'}->commit;
	}
	return;
}

sub _print_message_fieldset {
	my ( $self, $submission_id, $options ) = @_;
	$options = {} if ref $options ne 'HASH';
	my $q = $self->{'cgi'};
	if ( $q->param('message') ) {
		my $user = $self->{'datastore'}->get_user_info_from_username( $self->{'username'} );
		if ( !$user ) {
			$logger->error("Invalid user.");
			return;
		}
		eval {
			$self->{'db'}->do( "INSERT INTO messages (submission_id,timestamp,user_id,message) VALUES (?,?,?,?)",
				undef, $submission_id, 'now', $user->{'id'}, $q->param('message') );
		};
		if ($@) {
			$logger->error($@);
			$self->{'db'}->rollback;
		} else {
			$self->{'db'}->commit;
			$self->_append_message( $submission_id, $user->{'id'}, $q->param('message') );
			$q->delete('message');
		}
	}
	my $buffer;
	my $messages =
	  $self->{'datastore'}->run_query(
		"SELECT date_trunc('second',timestamp) AS timestamp,user,message FROM messages WHERE submission_id=? ORDER BY timestamp asc",
		$submission_id, { fetch => 'all_arrayref', slice => {} } );
	if (@$messages) {
		$buffer .= qq(<table class="resultstable"><tr><th>Timestamp</th><th>User</th><th>Message</th></tr>);
		my $td = 1;
		foreach my $message (@$messages) {
			my $user_string = $self->{'datastore'}->get_user_string( $message->{'user_id'} );
			$buffer .= qq(<tr class="td$td"><td>$message->{'timestamp'}</td><td>$user_string</td><td style="text-align:left">)
			  . qq($message->{'message'}</td></tr>);
			$td = $td == 1 ? 2 : 1;
		}
		$buffer .= qq(</table>);
	}
	if ( !$options->{'no_add'} ) {
		$buffer .= $q->start_form;
		$buffer .= q(<div>);
		$buffer .= $q->textarea( -name => 'message', -id => 'message', -style => 'width:100%' );
		$buffer .= q(</div><div style="float:right">);
		$buffer .= $q->submit( -name => 'Add message', -class => 'submitbutton ui-button ui-widget ui-state-default ui-corner-all' );
		$buffer .= q(</div>);
		$buffer .= $q->hidden($_) foreach qw(db page alleles locus submit continue view curate abort submission_id no_check);
		$buffer .= $q->end_form;
	}
	say qq(<fieldset style="float:left"><legend>Messages</legend>$buffer</fieldset>) if $buffer;
	return;
}

sub _print_archive_fieldset {
	my ( $self, $submission_id ) = @_;
	say qq(<fieldset style="float:left"><legend>Archive</legend>);
	say qq(<p>Archive of submission and any supporting files:</p>);
	my $tar_icon = $self->get_file_icon('TAR');
	say qq(<p><a href="$self->{'system'}->{'script_name'}?db=$self->{'instance'}&amp;page=submit&amp;submission_id=$submission_id&amp;)
	  . qq(tar=1">Download$tar_icon</a></p>);
	say qq(</fieldset>);
	return;
}

sub _print_finalize_fieldset {
	my ( $self, $submission_id ) = @_;
	return if !$self->{'all_assigned_or_rejected'};
	my $q = $self->{'cgi'};
	say $q->start_form;
	$q->param( finalize => 1 );
	say $q->hidden($_) foreach qw( db page submission_id finalize );
	$self->print_action_fieldset( { no_reset => 1, submit_label => 'Finalize submission' } );
	say $q->end_form;
	return;
}

sub _append_message {
	my ( $self, $submission_id, $user_id, $message ) = @_;
	my $dir = $self->_get_submission_dir($submission_id);
	$dir = $dir =~ /^($self->{'config'}->{'submission_dir'}\/BIGSdb[^\/]+$)/ ? $1 : undef;    #Untaint
	make_path $dir;
	my $filename = 'messages.txt';
	open( my $fh, '>>:encoding(utf8)', "$dir/$filename" ) || $logger->error("Can't open $dir/$filename for appending");
	my $user_string = $self->{'datastore'}->get_user_string($user_id);
	say $fh $user_string;
	my $timestamp = localtime(time);
	say $fh $timestamp;
	say $fh $message;
	say $fh '';
	close $fh;
	return;
}

sub _print_submission_file_table {
	my ( $self, $submission_id, $options ) = @_;
	$options = {} if ref $options ne 'HASH';
	my $q     = $self->{'cgi'};
	my $files = $self->_get_submission_files($submission_id);
	return if !@$files;
	my $buffer = qq(<table class="resultstable"><tr><th>Filename</th><th>Size</th>);
	$buffer .= qq(<th>Delete</th>) if $options->{'delete_checkbox'};
	$buffer .= qq(</tr>\n);
	my $td = 1;
	my $i  = 0;

	foreach my $file (@$files) {
		$buffer .= qq(<tr class="td$td"><td><a href="/submissions/$submission_id/supporting_files/$file->{'filename'}">)
		  . qq($file->{'filename'}</a></td><td>$file->{'size'}</td>);
		if ( $options->{'delete_checkbox'} ) {
			$buffer .= qq(<td>);
			$buffer .= $q->checkbox( -name => "file$i", -label => '' );
			$buffer .= qq(</td>);
		}
		$i++;
		$buffer .= qq(</tr>\n);
		$td = $td == 1 ? 2 : 1;
	}
	$buffer .= qq(</table>);
	return $buffer if $options->{'get_only'};
	say $buffer;
	return;
}

sub _get_submission_files {
	my ( $self, $submission_id ) = @_;
	my $dir = $self->_get_submission_dir($submission_id) . "/supporting_files";
	return [] if !-e $dir;
	my @files;
	opendir( my $dh, $dir ) || $logger->error("Can't open directory $dir");
	while ( my $filename = readdir $dh ) {
		next if $filename =~ /^\./;
		next if $filename =~ /^submission/;    #Temp file created by script
		push @files, { filename => $filename, size => BIGSdb::Utils::get_nice_size( -s "$dir/$filename" ) };
	}
	closedir $dh;
	return \@files;
}

sub _get_submission_dir {
	my ( $self, $submission_id ) = @_;
	return "$self->{'config'}->{'submission_dir'}/$submission_id";
}

sub _upload_files {
	my ( $self, $submission_id ) = @_;
	my $q         = $self->{'cgi'};
	my @filenames = $q->param('file_upload');
	my $i         = 0;
	my $dir       = $self->_get_submission_dir($submission_id) . '/supporting_files';
	if ( !-e $dir ) {
		make_path $dir || $logger->error("Cannot create $dir directory.");
	}
	foreach my $fh2 ( $q->upload('file_upload') ) {
		if ( $filenames[$i] =~ /([A-z0-9_\-\.'\ \(\)]+)/ ) {
			$filenames[$i] = $1;
		} else {
			$filenames[$i] = 'file';
		}
		my $filename = "$dir/$filenames[$i]";
		$i++;
		next if -e $filename;    #Don't reupload if already done.
		my $buffer;
		open( my $fh, '>', $filename ) || $logger->error("Could not open $filename for writing.");
		binmode $fh2;
		binmode $fh;
		read( $fh2, $buffer, MAX_UPLOAD_SIZE );
		print $fh $buffer;
		close $fh;
	}
	return \@filenames;
}

sub _view_submission {
	my ( $self, $submission_id ) = @_;
	my $submission = $self->_get_submission($submission_id);
	say qq(<h1>Submission summary</h1>);
	if ( !$submission ) {
		say qq(<div class="box" id="statusbad"><p>The submission does not exist.</p></div>);
		return;
	}
	say qq(<div class="box" id="resultstable"><div class="scrollable">);
	say qq(<h2>Submission: $submission_id</h2>);
	$self->_print_summary($submission_id);
	$self->_print_sequence_table_fieldset($submission_id);
	$self->_print_file_fieldset($submission_id);
	$self->_print_message_fieldset($submission_id);
	$self->_print_archive_fieldset($submission_id);
	say qq(</div></div>);
	return;
}

sub _print_file_fieldset {
	my ( $self, $submission_id ) = @_;
	my $file_table = $self->_print_submission_file_table( $submission_id, { get_only => 1 } );
	if ($file_table) {
		say qq(<fieldset style="float:left"><legend>Supporting files</legend>);
		say $file_table;
		say qq(</fieldset>);
	}
	return;
}

sub _print_summary {
	my ( $self, $submission_id ) = @_;
	my $submission = $self->_get_submission($submission_id);
	say qq(<fieldset style="float:left"><legend>Summary</legend>);
	say qq(<dl class="data"><dt>type</dt><dd>$submission->{'type'}</dd>);
	my $user_string = $self->{'datastore'}->get_user_string( $submission->{'submitter'}, { email => 1, affiliation => 1 } );
	say qq(<dt>submitter</dt><dd>$user_string</dd>);
	say qq(<dt>datestamp</dt><dd>$submission->{'datestamp'}</dd>);
	say qq(<dt>status</dt><dd>$submission->{'status'}</dd>);

	if ( $submission->{'type'} eq 'alleles' ) {
		my $allele_submission = $self->get_allele_submission($submission_id);
		say qq(<dt>locus</dt><dd>$allele_submission->{'locus'}</dd>);
		my $allele_count   = @{ $allele_submission->{'seqs'} };
		my $fasta_icon     = $self->get_file_icon('FAS');
		my $submission_dir = $self->_get_submission_dir($submission_id);
		if ( -e "$submission_dir/sequences.fas" ) {
			say qq(<dt>sequences</dt><dd><a href="/submissions/$submission_id/sequences.fas">$allele_count$fasta_icon</a></dd>);
		} else {
			$logger->error("No submission FASTA file for allele submission $submission_id.");
		}
		say qq(<dt>technology</dt><dd>$allele_submission->{'technology'}</dd>);
		say qq(<dt>read length</dt><dd>$allele_submission->{'read_length'}</dd>) if $allele_submission->{'read_length'};
		say qq(<dt>coverage</dt><dd>$allele_submission->{'coverage'}</dd>)       if $allele_submission->{'coverage'};
		say qq(<dt>assembly</dt><dd>$allele_submission->{'assembly'}</dd>);
		say qq(<dt>assembly software</dt><dd>$allele_submission->{'software'}</dd>);
	}
	say qq(</dl></fieldset>);
	return;
}

sub _curate_submission {
	my ( $self, $submission_id ) = @_;
	say qq(<h1>Curate submission</h1>);
	if ( !$submission_id ) {
		say qq(<div class="box" id="statusbad"><p>No submission id passed.</p></div>);
		return;
	}
	my $user_info = $self->{'datastore'}->get_user_info_from_username( $self->{'username'} );
	if ( !$user_info || ( $user_info->{'status'} ne 'admin' && $user_info->{'status'} ne 'curator' ) ) {
		say qq(<div class="box" id="statusbad"><p>Your account does not have the required permissions to curate this submission.</p></div>);
		return;
	}
	my $submission = $self->_get_submission($submission_id);
	if ( !$submission ) {
		say qq(<div class="box" id="statusbad"><p>There is no submission '$submission_id' available for curation.</p></div>);
		return;
	}
	say qq(<div class="box" id="resultstable"><div class="scrollable">);
	say qq(<h2>Submission: $submission_id</h2>);
	$self->_print_summary($submission_id);
	$self->_print_sequence_table_fieldset( $submission_id, { curate => 1 } );
	$self->_print_file_fieldset($submission_id);
	$self->_print_message_fieldset($submission_id);
	$self->_print_archive_fieldset($submission_id);
	$self->_print_finalize_fieldset($submission_id);
	say qq(</div></div>);
	return;
}

sub _get_fasta_string {
	my ( $self, $seqs ) = @_;
	my $buffer;
	foreach my $seq (@$seqs) {
		$buffer .= ">$seq->{'seq_id'}\n";
		$buffer .= "$seq->{'sequence'}\n";
	}
	return $buffer;
}

sub _write_allele_FASTA {
	my ( $self, $submission_id ) = @_;
	my $allele_submission = $self->get_allele_submission($submission_id);
	my $seqs              = $allele_submission->{'seqs'};
	return if !@$seqs;
	my $dir = $self->_get_submission_dir($submission_id);
	$dir = $dir =~ /^($self->{'config'}->{'submission_dir'}\/BIGSdb[^\/]+$)/ ? $1 : undef;    #Untaint
	make_path $dir;
	my $filename = 'sequences.fas';
	open( my $fh, '>', "$dir/$filename" ) || $logger->error("Can't open $dir/$filename for writing");

	foreach my $seq (@$seqs) {
		say $fh ">$seq->{'seq_id'}";
		say $fh $seq->{'sequence'};
	}
	close $fh;
	return $filename;
}

sub _tar_archive {
	my ( $self, $submission_id ) = @_;
	return if !defined $submission_id || $submission_id !~ /BIGSdb_\d+/;
	my $submission = $self->_get_submission($submission_id);
	return if !$submission;
	my $submission_dir = $self->_get_submission_dir($submission_id);
	$submission_dir = $submission_dir =~ /^($self->{'config'}->{'submission_dir'}\/BIGSdb[^\/]+)$/ ? $1 : undef;    #Untaint
	binmode STDOUT;
	local $" = ' ';
	my $command = "cd $submission_dir && tar -cf - *";

	if ( $ENV{'MOD_PERL'} ) {
		print `$command`;    # http://modperlbook.org/html/6-4-8-Output-from-System-Calls.html
	} else {
		system $command || $logger->error("Can't create tar: $?");
	}
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
