#Written by Keith Jolley
#Copyright (c) 2010-2013, University of Oxford
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
package BIGSdb::IsolateInfoPage;
use strict;
use warnings;
use 5.010;
use parent qw(BIGSdb::TreeViewPage);
use Log::Log4perl qw(get_logger);
use Error qw(:try);
use List::MoreUtils qw(any none);
my $logger = get_logger('BIGSdb.Page');
use constant ISOLATE_SUMMARY => 1;
use constant LOCUS_SUMMARY   => 2;

sub set_pref_requirements {
	my ($self) = @_;
	$self->{'pref_requirements'} = { general => 1, main_display => 0, isolate_display => 1, analysis => 0, query_field => 0 };
	return;
}

sub initiate {
	my ($self) = @_;
	if ( $self->{'cgi'}->param('no_header') ) {
		$self->{'type'}    = 'no_header';
		$self->{'noCache'} = 1;
		return;
	}
	$self->{$_} = 1 foreach qw(jQuery jQuery.jstree jQuery.columnizer);
	return;
}

sub get_javascript {
	my ($self) = @_;
	my $buffer = << "END";
\$(function () {
	\$(document).ajaxComplete(function() {
		reloadTooltips();
		if (\$("span").hasClass('aliases')){
			\$("span#aliases_button").css('display', 'inline');
		} else {
			\$("span#aliases_button").css('display', 'none');
		}
	});
	\$( "#hidden_references" ).css('display', 'none');
	\$( "#show_refs" ).click(function() {
		\$( "#hidden_references" ).toggle( 'blind', {} , 500 );
		return false;
	});
	\$( "#sample_table" ).css('display', 'none');
	\$( "#show_samples" ).click(function() {
		\$( "#sample_table" ).toggle( 'blind', {} , 500 );
		return false;
	});
	\$( "#show_aliases" ).click(function() {
		\$( "span.aliases" ).toggle( 'highlight', {} , 500 );
		return false;
	});
	\$("#provenance").columnize({width:400});
	\$("#seqbin").columnize({
		width:300, 
		lastNeverTallest: true,
	});
	\$(".smallbutton").css('display', 'inline');
});

END
	$buffer .= $self->get_tree_javascript;
	return $buffer;
}

sub _get_child_group_scheme_tables {
	my ( $self, $id, $isolate_id, $level ) = @_;
	my $child_groups = $self->{'datastore'}->run_list_query(
		"SELECT id FROM scheme_groups LEFT JOIN scheme_group_group_members ON "
		  . "scheme_groups.id=group_id WHERE parent_group_id=? ORDER BY display_order",
		$id
	);
	my $buffer;
	if (@$child_groups) {
		foreach (@$child_groups) {
			my $group_info = $self->{'datastore'}->get_scheme_group_info($_);
			my $new_level  = $level;
			last if $new_level == 10;    #prevent runaway if child is set as the parent of a parental group
			my $field_buffer = $self->_get_group_scheme_tables( $_, $isolate_id );
			$buffer .= $field_buffer if $field_buffer;
			$field_buffer = $self->_get_child_group_scheme_tables( $_, $isolate_id, ++$new_level );
			$buffer .= $field_buffer if $field_buffer;
		}
	}
	return $buffer;
}

sub _get_group_scheme_tables {
	my ( $self, $id, $isolate_id ) = @_;
	my $set_id = $self->get_set_id;
	my $scheme_data = $self->{'datastore'}->get_scheme_list( { set_id => $set_id } );
	my ( $scheme_ids_ref, $desc_ref ) = $self->extract_scheme_desc($scheme_data);
	my $schemes = $self->{'datastore'}->run_list_query(
		"SELECT scheme_id FROM scheme_group_scheme_members LEFT JOIN schemes ON "
		  . "schemes.id=scheme_id WHERE group_id=? ORDER BY display_order",
		$id
	);
	my $buffer;
	if (@$schemes) {
		foreach my $scheme_id (@$schemes) {
			next if !$self->{'prefs'}->{'isolate_display_schemes'}->{$scheme_id};
			next if none { $scheme_id eq $_ } @$scheme_ids_ref;
			if ( !$self->{'scheme_shown'}->{$scheme_id} ) {
				$self->_print_scheme( $scheme_id, $isolate_id, $self->{'curate'} );
				$self->{'scheme_shown'}->{$scheme_id} = 1;
			}
		}
	}
	return $buffer;
}

sub print_content {
	my ($self)     = @_;
	my $q          = $self->{'cgi'};
	my $isolate_id = $q->param('id');
	my $set_id     = $self->get_set_id;
	my $scheme_data = $self->{'datastore'}->get_scheme_list( { set_id => $set_id } );
	my ( $scheme_ids_ref, $desc_ref ) = $self->extract_scheme_desc($scheme_data);
	if ( defined $q->param('group_id') && BIGSdb::Utils::is_int( $q->param('group_id') ) ) {
		my $group_id = $q->param('group_id');
		my $scheme_ids;
		my ($table_buffer);
		if ( $group_id == 0 ) {
			$scheme_ids =
			  $self->{'datastore'}->run_list_query(
				"SELECT id FROM schemes WHERE id NOT IN (SELECT scheme_id FROM scheme_group_scheme_members) ORDER BY display_order");
			foreach my $scheme_id (@$scheme_ids) {
				next if !$self->{'prefs'}->{'isolate_display_schemes'}->{$scheme_id};
				next if none { $scheme_id eq $_ } @$scheme_ids_ref;
				my $scheme_info = $self->{'datastore'}->get_scheme_info($scheme_id);
				$self->_print_scheme( $scheme_id, $isolate_id, $self->{'curate'} );
			}
		} else {
			$table_buffer = $self->_get_group_scheme_tables( $group_id, $isolate_id );
			say $table_buffer if $table_buffer;
			$table_buffer = $self->_get_child_group_scheme_tables( $group_id, $isolate_id, 1 );
			say $table_buffer if $table_buffer;
		}
		return;
	} elsif ( defined $q->param('scheme_id') && BIGSdb::Utils::is_int( $q->param('scheme_id') ) ) {
		my $scheme_id = $q->param('scheme_id');
		if ( $scheme_id == -1 ) {
			my $schemes = $self->{'datastore'}->run_list_query("SELECT id FROM schemes ORDER BY display_order,id");
			foreach ( @$schemes, 0 ) {
				next if $_ && !$self->{'prefs'}->{'isolate_display_schemes'}->{$_};
				$self->_print_scheme( $_, $isolate_id, $self->{'curate'} );
			}
		} else {
			$self->_print_scheme( $scheme_id, $isolate_id, $self->{'curate'} );
		}
		return;
	}
	if ( !defined $isolate_id || $isolate_id eq '' ) {
		say "<h1>Isolate information</h1>";
		say "<div class=\"box statusbad\"><p>No isolate id provided.</p></div>";
		return;
	} elsif ( !BIGSdb::Utils::is_int($isolate_id) ) {
		say "<h1>Isolate information: id-$isolate_id</h1>";
		say "<div class=\"box\" id=\"statusbad\"><p>Isolate id must be an integer.</p></div>";
		return;
	}
	if ( $self->{'system'}->{'dbtype'} ne 'isolates' ) {
		say "<h1>Isolate information</h1>";
		say "<div class=\"box\" id=\"statusbad\"><p>This function can only be called for isolate databases.</p></div>";
		return;
	}
	my $data = $self->{'datastore'}->run_simple_query_hashref( "SELECT * FROM $self->{'system'}->{'view'} WHERE id=?", $isolate_id );
	if ( !$data ) {
		say "<h1>Isolate information: id-$isolate_id</h1>";
		say "<div class=\"box\" id=\"statusbad\"><p>The database contains no record of this isolate.</p></div>";
		return;
	} elsif ( !$self->is_allowed_to_view_isolate($isolate_id) ) {
		say "<h1>Isolate information</h1>";
		say "<div class=\"box\" id=\"statusbad\"><p>Your user account does not have permission to view this record.</p></div>";
		return;
	}
	if ( defined $data->{ $self->{'system'}->{'labelfield'} } && $data->{ $self->{'system'}->{'labelfield'} } ne '' ) {
		my $identifier = $self->{'system'}->{'labelfield'};
		$identifier =~ tr/_/ /;
		say "<h1>Full information on $identifier $data->{lc($self->{'system'}->{'labelfield'})}</h1>";
	} else {
		say "<h1>Full information on id $data->{'id'}</h1>";
	}
	if ( $self->{'cgi'}->param('history') ) {
		say "<div class=\"box\" id=\"resultstable\">";
		say "<h2>Update history</h2>";
		say "<p><a href=\"$self->{'system'}->{'script_name'}?page=info&amp;db=$self->{'instance'}&amp;id=$isolate_id\">"
		  . "Back to isolate information</a></p>";
		say $self->_get_update_history($isolate_id);
		say "</div>";
	} else {
		$self->_print_projects($isolate_id);
		say "<div class=\"box\" id=\"resultspanel\">";
		say $self->get_isolate_record($isolate_id);
		my $aliases_button = " <span id=\"aliases_button\" style=\"margin-left:1em;display:none\">"
		  . "<a id=\"show_aliases\" class=\"smallbutton\" style=\"cursor:pointer\">&nbsp;show/hide locus aliases&nbsp;</a></span>";
		say "<h2>Schemes and loci$aliases_button</h2>";
		say $self->_get_tree($isolate_id);
		say "</div>";
	}
	return;
}

sub _get_update_history {
	my ( $self,    $isolate_id )  = @_;
	my ( $history, $num_changes ) = $self->_get_history($isolate_id);
	my $buffer = '';
	if ($num_changes) {
		$buffer .= "<table class=\"resultstable\"><tr><th>Timestamp</th><th>Curator</th><th>Action</th></tr>\n";
		my $td = 1;
		foreach (@$history) {
			my $curator_info = $self->{'datastore'}->get_user_info( $_->{'curator'} );
			my $time         = $_->{'timestamp'};
			$time =~ s/:\d\d\.\d+//;
			my $action = $_->{'action'};
			$action =~ s/->/\&rarr;/g;
			$buffer .= "<tr class=\"td$td\"><td style=\"vertical-align:top\">$time</td><td style=\"vertical-align:top\">"
			  . "$curator_info->{'first_name'} $curator_info->{'surname'}</td><td style=\"text-align:left\">$action</td></tr>\n";
			$td = $td == 1 ? 2 : 1;
		}
		$buffer .= "</table>\n";
	}
	return $buffer;
}

sub get_isolate_summary {
	my ( $self, $id ) = @_;
	return $self->get_isolate_record( $id, ISOLATE_SUMMARY );
}

sub get_loci_summary {
	my ( $self, $id ) = @_;
	return $self->get_isolate_record( $id, LOCUS_SUMMARY );
}

sub get_isolate_record {
	my ( $self, $id, $summary_view ) = @_;
	$summary_view ||= 0;
	my $buffer;
	my $q = $self->{'cgi'};
	my $data = $self->{'datastore'}->run_simple_query_hashref( "SELECT * FROM $self->{'system'}->{'view'} WHERE id=?", $id );
	if ( !$data ) {
		$logger->error("Record $id does not exist");
		throw BIGSdb::DatabaseNoRecordException("Record $id does not exist");
	}
	$self->add_existing_metadata_to_hashref($data);
	$buffer .= "<div class=\"scrollable\">";
	if ( $summary_view == LOCUS_SUMMARY ) {
		$buffer .= $self->_get_tree($id);
	} else {
		$buffer .= $self->_get_provenance_fields( $id, $data, $summary_view );
		if ( !$summary_view ) {
			$buffer .= $self->_get_ref_links($id);
			$buffer .= $self->_get_seqbin_link($id);
			$buffer .= $self->get_sample_summary( $id, { hide => 1 } );
		}
	}
	$buffer .= "</div>\n";
	return $buffer;
}

sub _get_provenance_fields {
	my ( $self, $isolate_id, $data, $summary_view ) = @_;
	my $buffer = "<h2>Provenance/meta data</h2>\n";
	$buffer .= "<div id=\"provenance\">\n";
	$buffer .= "<dl class=\"data\">\n";
	my $q             = $self->{'cgi'};
	my $set_id        = $self->get_set_id;
	my $metadata_list = $self->{'datastore'}->get_set_metadata( $set_id, { curate => $self->{'curate'} } );
	my $field_list    = $self->{'xmlHandler'}->get_field_list($metadata_list);
	my ( %composites, %composite_display_pos );
	my $composite_data = $self->{'datastore'}->run_list_query_hashref("SELECT id,position_after FROM composite_fields");

	foreach (@$composite_data) {
		$composite_display_pos{ $_->{'id'} }  = $_->{'position_after'};
		$composites{ $_->{'position_after'} } = 1;
	}
	my $field_with_extended_attributes;
	if ( !$summary_view ) {
		$field_with_extended_attributes =
		  $self->{'datastore'}->run_list_query("SELECT DISTINCT isolate_field FROM isolate_field_extended_attributes");
	}
	foreach my $field (@$field_list) {
		my ( $metaset, $metafield ) = $self->get_metaset_and_fieldname($field);
		my $displayfield = $metafield // $field;
		$displayfield .= " <span class=\"metaset\">Metadata: $metaset</span>" if !$set_id && defined $metaset;
		$displayfield =~ tr/_/ /;
		my $thisfield = $self->{'xmlHandler'}->get_field_attributes($field);
		my $web;
		my $value = $data->{ lc($field) };
		if ( !defined $value ) {

			if ( $composites{$field} ) {
				$buffer .= $self->_get_composite_field_rows( $isolate_id, $data, $field, \%composite_display_pos );
			}
			next;

			#Do not print row
		} elsif ( $thisfield->{'web'} ) {
			my $url = $thisfield->{'web'};
			$url =~ s/\[\\*\?\]/$value/;
			$url =~ s/\&/\&amp;/g;
			my $domain;
			if ( ( lc($url) =~ /http:\/\/(.*?)\/+/ ) ) {
				$domain = $1;
			}
			$web = "<a href=\"$url\">$value</a>";
			if ( $domain && $domain ne $q->virtual_host ) {
				$web .= " <span class=\"link\"><span style=\"font-size:1.2em\">&rarr;</span> $domain</span>";
			}
		}
		if (   ( $field eq 'curator' )
			|| ( $field eq 'sender' )
			|| ( $thisfield->{'userfield'} && $thisfield->{'userfield'} eq 'yes' ) )
		{
			my $userdata = $self->{'datastore'}->get_user_info($value);
			my $colspan  = $summary_view ? 5 : 2;
			my $person   = "$userdata->{first_name} $userdata->{surname}";
			if ( !$summary_view && !( $field eq 'sender' && $data->{'sender'} == $data->{'curator'} ) ) {
				$person .= ", $userdata->{affiliation}" if $value > 0;
				if (
					$field eq 'curator'
					|| ( ( $field eq 'sender' || ( ( $thisfield->{'userfield'} // '' ) eq 'yes' ) )
						&& !$self->{'system'}->{'privacy'} )
				  )
				{
					if ( $value > 0 && $userdata->{'email'} ne '' && $userdata->{'email'} ne '-' ) {
						$person .= " (E-mail: <a href=\"mailto:$userdata->{'email'}\">$userdata->{'email'}</a>)";
					}
				}
			}
			$buffer .= "<dt class=\"dontend\">$displayfield</dt>\n";
			$buffer .= "<dd>$person</dd>\n";
			if ( $field eq 'curator' ) {
				my ( $history, $num_changes ) = $self->_get_history( $isolate_id, 10 );
				if ($num_changes) {
					my $plural = $num_changes == 1 ? '' : 's';
					my $title;
					$title = "Update history - ";
					foreach (@$history) {
						my $time = $_->{'timestamp'};
						$time =~ s/ \d\d:\d\d:\d\d\.\d+//;
						my $action = $_->{'action'};
						if ( $action =~ /<br \/>/ ) {
							$action = 'multiple updates';
						}
						$action =~ s/[\r\n]//g;
						$action =~ s/:.*//;
						$title .= "$time: $action<br />";
					}
					if ( $num_changes > 10 ) {
						$title .= "more ...";
					}
					$buffer .= "<dt class=\"dontend\">update history</dt>\n";
					$buffer .= "<dd><a title=\"$title\" class=\"update_tooltip\">$num_changes update$plural</a>";
					my $refer_page = $q->param('page');
					$buffer .= " <a href=\"$self->{'system'}->{'script_name'}?page=info&amp;db=$self->{'instance'}&amp;id=$isolate_id&amp;"
					  . "history=1&amp;refer=$refer_page\">show details</a></dd>\n";
				}
			}
		} else {
			$buffer .= "<dt class=\"dontend\">$displayfield</dt>\n";
			$buffer .= "<dd>" . ( $web || $value ) . "</dd>\n";
		}
		if (
			any {
				$field eq $_;
			}
			@$field_with_extended_attributes
		  )
		{
			my $attribute_order =
			  $self->{'datastore'}
			  ->run_list_query_hashref( "SELECT attribute,field_order FROM isolate_field_extended_attributes WHERE isolate_field=?",
				$field );
			my %order = map { $_->{'attribute'} => $_->{'field_order'} } @$attribute_order;
			my $attribute_list =
			  $self->{'datastore'}->run_list_query_hashref(
				"SELECT attribute,value FROM isolate_value_extended_attributes WHERE isolate_field=? AND field_value=?",
				$field, $value );
			my %attributes = map { $_->{'attribute'} => $_->{'value'} } @$attribute_list;
			if ( keys %attributes ) {
				my $rows = keys %attributes || 1;
				foreach ( sort { $order{$a} <=> $order{$b} } keys(%attributes) ) {
					my $url_ref =
					  $self->{'datastore'}
					  ->run_simple_query( "SELECT url FROM isolate_field_extended_attributes WHERE isolate_field=? AND attribute=?",
						$field, $_ );
					my $att_web;
					if ( ref $url_ref eq 'ARRAY' ) {
						my $url = $url_ref->[0] || '';
						$url =~ s/\[\?\]/$attributes{$_}/;
						$url =~ s/\&/\&amp;/g;
						my $domain;
						if ( ( lc($url) =~ /http:\/\/(.*?)\/+/ ) ) {
							$domain = $1;
						}
						$att_web = "<a href=\"$url\">$attributes{$_}</a>" if $url;
						if ( $domain && $domain ne $q->virtual_host ) {
							$att_web .= " <span class=\"link\"><span style=\"font-size:1.2em\">&rarr;</span> $domain</span>";
						}
					}
					$buffer .= "<dt class=\"dontend\">$_</dt>\n";
					$buffer .= "<dd>" . ( $att_web || $attributes{$_} ) . "</dd>\n";
				}
			}
		}
		if ( $field eq $self->{'system'}->{'labelfield'} ) {
			my $aliases =
			  $self->{'datastore'}->run_list_query( "SELECT alias FROM isolate_aliases WHERE isolate_id=? ORDER BY alias", $isolate_id );
			if (@$aliases) {
				local $" = '; ';
				my $plural = @$aliases > 1 ? 'es' : '';
				$buffer .= "<dt class=\"dontend\">alias$plural</dt>\n";
				$buffer .= "<dd>@$aliases</dd>\n";
			}
		}
		if ( $composites{$field} ) {
			$buffer .= $self->_get_composite_field_rows( $isolate_id, $data, $field, \%composite_display_pos );
		}
	}
	$buffer .= "</dl></div>\n";
	return $buffer;
}

sub _get_composite_field_rows {
	my ( $self, $isolate_id, $data, $field_to_position_after, $composite_display_pos ) = @_;
	my $buffer = '';
	foreach ( keys %$composite_display_pos ) {
		next if $composite_display_pos->{$_} ne $field_to_position_after;
		my $displayfield = $_;
		$displayfield =~ tr/_/ /;
		my $value = $self->{'datastore'}->get_composite_value( $isolate_id, $_, $data );
		$buffer .= "<dt class=\"dontend\">$displayfield</dt>\n";
		$buffer .= "<dd>$value</dd>\n";
	}
	return $buffer;
}

sub _get_tree {
	my ( $self, $isolate_id ) = @_;
	my $buffer = "<div class=\"scrollable\"><div id=\"tree\" class=\"scheme_tree\" style=\"float:left\">\n";
	$buffer .= "<noscript><p class=\"highlight\">Enable Javascript to enhance your viewing experience.</p></noscript>\n";
	$buffer .= $self->get_tree( $isolate_id, { isolate_display => $self->{'curate'} ? 0 : 1 } );
	$buffer .= "</div>\n";
	$buffer .= "<div id=\"scheme_table\" style=\"float:left\">Navigate and select schemes within tree to display allele "
	  . "designations</div><div style=\"clear:both\"></div></div>\n";
	return $buffer;
}

sub get_sample_summary {
	my ( $self, $id, $options ) = @_;
	$options = {} if ref $options ne 'HASH';
	my ($sample_buffer) = $self->_get_samples($id);
	my $buffer = '';
	if ($sample_buffer) {
		my $display = $options->{'hide'} ? 'none' : 'block';
		if ( $options->{'hide'} ) {
			$buffer .= "<h2>Samples";
			$buffer .= "<span style=\"margin-left:1em\"><a id=\"show_samples\" class=\"smallbutton\" style=\"cursor:pointer;display:none\">"
			  . "&nbsp;show/hide&nbsp;</a></span></h2>\n";
		}
		$buffer .= "<table class=\"resultstable\" id=\"sample_table\">\n";
		$buffer .= $sample_buffer;
		$buffer .= "</table>\n";
	}
	return $buffer;
}

sub _get_samples {
	my ( $self, $id ) = @_;
	my $td            = 1;
	my $buffer        = '';
	my $sample_fields = $self->{'xmlHandler'}->get_sample_field_list;
	my ( @selected_fields, @clean_fields );
	foreach my $field (@$sample_fields) {
		next if $field eq 'isolate_id';
		my $attributes = $self->{'xmlHandler'}->get_sample_field_attributes($field);
		next if ( $attributes->{'maindisplay'} // '' ) eq 'no';
		push @selected_fields, $field;
		( my $clean = $field ) =~ tr/_/ /;
		push @clean_fields, $clean;
	}
	if (@selected_fields) {
		my $samples = $self->{'datastore'}->get_samples($id);
		my @sample_rows;
		foreach my $sample (@$samples) {
			foreach my $field (@$sample_fields) {
				if ( $field eq 'sender' || $field eq 'curator' ) {
					my $user_info = $self->{'datastore'}->get_user_info( $sample->{$field} );
					$sample->{$field} = "$user_info->{'first_name'} $user_info->{'surname'}";
				}
			}
			my $row = "<tr class=\"td$td\">";
			if ( $self->{'curate'} ) {
				$row .=
				    "<td><a href=\"$self->{'system'}->{'script_name'}?db=$self->{'instance'}&amp;page=delete&amp;table=samples&amp;"
				  . "isolate_id=$id&amp;sample_id=$sample->{'sample_id'}\">Delete</a></td>"
				  . "<td><a href=\"$self->{'system'}->{'script_name'}?db=$self->{'instance'}&amp;page=update&amp;table=samples&amp;"
				  . "isolate_id=$id&amp;sample_id=$sample->{'sample_id'}\">Update</a></td>";
			}
			foreach my $field (@selected_fields) {
				$sample->{$field} = defined $sample->{$field} ? $sample->{$field} : '';
				if ( $field eq 'sample_id' && $self->{'prefs'}->{'sample_details'} ) {
					my $info = "Sample $sample->{$field} - ";
					foreach my $field (@$sample_fields) {
						next if $field eq 'sample_id' || $field eq 'isolate_id';
						( my $clean = $field ) =~ tr/_/ /;
						$info .= "$clean: $sample->{$field}&nbsp;<br />"
						  if defined $sample->{$field};    #nbsp added to stop Firefox truncating text
					}
					$row .= "<td>$sample->{$field}<span style=\"font-size:0.5em\"> </span><a class=\"update_tooltip\" "
					  . "title=\"$info\">&nbsp;...&nbsp;</a></td>";
				} else {
					$row .= "<td>$sample->{$field}</td>";
				}
			}
			$row .= "</tr>";
			push @sample_rows, $row;
			$td = $td == 1 ? 2 : 1;
		}
		if (@sample_rows) {
			my $rows = scalar @sample_rows + 1;
			local $" = '</th><th>';
			$buffer .= "<tr>";
			$buffer .= "<td><table style=\"width:100%\"><tr>";
			if ( $self->{'curate'} ) {
				$buffer .= "<th>Delete</th><th>Update</th>";
			}
			$buffer .= "<th>@clean_fields</th></tr>";
			local $" = "\n";
			$buffer .= "@sample_rows";
			$buffer .= "</table></td></tr>\n";
		}
	}
	return $buffer;
}

sub _get_loci_not_in_schemes {
	my ( $self, $isolate_id ) = @_;
	my $set_id = $self->get_set_id;
	my $loci;
	my $loci_in_no_scheme = $self->{'datastore'}->get_loci_in_no_scheme( { set_id => $set_id } );
	if ( $self->{'prefs'}->{'undesignated_alleles'} ) {
		$loci = $loci_in_no_scheme;
	} else {
		my $loci_with_designations =
		  $self->{'datastore'}->run_list_query( "SELECT locus FROM allele_designations WHERE isolate_id=?", $isolate_id );
		my %designations = map { $_ => 1 } @$loci_with_designations;
		my $loci_with_tags =
		  $self->{'datastore'}->run_list_query(
			"SELECT DISTINCT locus FROM allele_sequences LEFT JOIN sequence_bin ON seqbin_id=sequence_bin.id WHERE isolate_id=?",
			$isolate_id );
		my %tags = map { $_ => 1 } @$loci_with_tags;
		foreach my $locus (@$loci_in_no_scheme) {
			next if !$designations{$locus} && !$tags{$locus};
			push @$loci, $locus;
		}
	}
	return $loci // [];
}

sub _should_display_scheme {
	my ( $self, $isolate_id, $scheme_id, $summary_view ) = @_;
	my $set_id = $self->get_set_id;
	my $scheme_data = $self->{'datastore'}->get_scheme_list( { set_id => $set_id } );
	my ( $scheme_ids_ref, $desc_ref ) = $self->extract_scheme_desc($scheme_data);
	return 0 if none { $scheme_id eq $_ } @$scheme_ids_ref;
	my $scheme_fields      = $self->{'datastore'}->get_scheme_fields($scheme_id);
	my $loci               = $self->{'datastore'}->get_scheme_loci($scheme_id);
	my $designations_exist = $self->{'datastore'}->run_simple_query(
		"SELECT EXISTS(SELECT isolate_id FROM allele_designations LEFT JOIN scheme_members ON scheme_members.locus="
		  . "allele_designations.locus WHERE isolate_id=? AND scheme_id=?)",
		$isolate_id, $scheme_id
	)->[0];
	my $sequences_exist = $self->{'datastore'}->run_simple_query(
		"SELECT EXISTS(SELECT isolate_id FROM allele_sequences LEFT JOIN sequence_bin ON allele_sequences.seqbin_id="
		  . "sequence_bin.id LEFT JOIN scheme_members ON allele_sequences.locus=scheme_members.locus WHERE isolate_id=? "
		  . "AND scheme_id=?)",
		$isolate_id, $scheme_id
	)->[0];
	my $should_display = ( $designations_exist || $sequences_exist ) ? 1 : 0;
	return $should_display;
}

sub _get_scheme_field_values {
	my ( $self, $isolate_id, $scheme_id, $scheme_fields, $profile ) = @_;
	my %values;
	my $scheme_field_values = $self->{'datastore'}->get_scheme_field_values_by_profile( $scheme_id, $profile );
	if ( defined $scheme_field_values && ref $scheme_field_values eq 'HASH' ) {
		foreach my $field (@$scheme_fields) {
			my $value = $scheme_field_values->{ lc($field) };
			$value = defined $value ? $value : '';
			$value = 'Not defined' if $value eq '-999' || $value eq '';
			my $att = $self->{'datastore'}->get_scheme_field_info( $scheme_id, $field );
			if ( $att->{'url'} && $value ne '' ) {
				my $url = $att->{'url'};
				$url =~ s/\[\?\]/$value/g;
				$url =~ s/\&/\&amp;/g;
				$values{$field} = "<a href=\"$url\">$value</a>";
			} else {
				$values{$field} = $value;
			}
		}
	} else {
		$values{$_} = 'Not defined' foreach @$scheme_fields;
	}
	return \%values;
}

sub _print_scheme {
	my ( $self, $scheme_id, $isolate_id, $summary_view ) = @_;
	my $q = $self->{'cgi'};
	my ( $locus_display_count, $scheme_fields_count ) = ( 0, 0 );
	my ( $loci, $scheme_fields, $scheme_info );
	my $set_id = $self->get_set_id;
	if ($scheme_id) {
		my $should_display = $self->_should_display_scheme( $isolate_id, $scheme_id, $summary_view );
		return if !$should_display;
		$scheme_fields = $self->{'datastore'}->get_scheme_fields($scheme_id);
		$loci          = $self->{'datastore'}->get_scheme_loci($scheme_id);
		foreach (@$loci) {
			$locus_display_count++ if $self->{'prefs'}->{'isolate_display_loci'}->{$_} ne 'hide';
		}
		$scheme_info = $self->{'datastore'}->get_scheme_info( $scheme_id, { set_id => $set_id, get_pk => 1 } );
		foreach (@$scheme_fields) {
			$scheme_fields_count++ if $self->{'prefs'}->{'isolate_display_scheme_fields'}->{$scheme_id}->{$_};
		}
	} else {
		$scheme_fields = [];
		$loci          = $self->_get_loci_not_in_schemes($isolate_id);
		if (@$loci) {
			foreach (@$loci) {
				$locus_display_count++ if $self->{'prefs'}->{'isolate_display_loci'}->{$_} ne 'hide';
			}
			$scheme_info->{'description'} = 'Loci not in schemes';
		}
	}
	return if !( $locus_display_count + $scheme_fields_count );
	my $hidden_locus_count = 0;
	my $locus_alias        = $self->{'datastore'}->get_scheme_locus_aliases($scheme_id);
	my %locus_aliases;
	foreach (@$loci) {
		my $aliases;
		foreach my $alias ( sort keys %{ $locus_alias->{$_} } ) {
			$alias =~ s/^([A-Za-z]{1,3})_/<sup>$1<\/sup>/ if ( $self->{'system'}->{'locus_superscript_prefix'} // '' ) eq 'yes';
			push @$aliases, $alias;
		}
		$locus_aliases{$_} = $aliases;
		$hidden_locus_count++
		  if $self->{'prefs'}->{'isolate_display_loci'}->{$_} eq 'hide';
	}
	say "<h3 class=\"scheme\" style=\"clear:both\">$scheme_info->{'description'}</h3>";
	my $allele_designations = $self->{'datastore'}->get_scheme_allele_designations( $isolate_id, $scheme_id, { set_id => $set_id } );
	my @args = (
		{
			loci                => $loci,
			locus_aliases       => \%locus_aliases,
			allele_designations => $allele_designations,
			summary_view        => $summary_view,
			scheme_id           => $scheme_id,
			scheme_fields_count => $scheme_fields_count,
			isolate_id          => $isolate_id
		}
	);
	$self->_print_scheme_values(@args);
	return;
}

sub _print_scheme_values {
	my ( $self, $args ) = @_;
	my ( $isolate_id, $loci, $scheme_id, $scheme_fields_count, $allele_designations, $locus_aliases ) =
	  @{$args}{qw ( isolate_id loci scheme_id scheme_fields_count allele_designations locus_aliases)};
	my $scheme_fields = $self->{'datastore'}->get_scheme_fields($scheme_id);
	my @profile;
	my %provisional_allele;
	local $| = 1;
	foreach my $locus (@$loci) {
		push @profile, $allele_designations->{$locus}->{'allele_id'};
		next if $self->{'prefs'}->{'isolate_display_loci'}->{$locus} eq 'hide';
		$allele_designations->{$locus}->{'status'} ||= 'confirmed';
		$provisional_allele{$locus} = 1
		  if $self->{'prefs'}->{'mark_provisional'} && $allele_designations->{$locus}->{'status'} eq 'provisional';
		my $locus_value = '';
		$locus_value .= "<span class=\"provisional\">" if $provisional_allele{$locus};
		my $cleaned_name = $self->clean_locus($locus);
		my $tooltip_name = $cleaned_name;
		my $locus_info   = $self->{'datastore'}->get_locus_info($locus);

		if ( defined $allele_designations->{$locus}->{'allele_id'} ) {
			my $url = '';
			if ( $locus_info->{'url'} && $allele_designations->{$locus}->{'allele_id'} ne 'deleted' ) {
				$url = $locus_info->{'url'};
				$url =~ s/\[\?\]/$allele_designations->{$locus}->{'allele_id'}/g;
				$url =~ s/\&/\&amp;/g;
				$locus_value .= "<a href=\"$url\">$allele_designations->{$locus}->{'allele_id'}</a>";
			} else {
				$locus_value .= "$allele_designations->{$locus}->{'allele_id'}";
			}
			$locus_value .= "</span>" if $provisional_allele{$locus};
			if ( $self->{'prefs'}->{'update_details'} && $allele_designations->{$locus}->{'allele_id'} ) {
				my $update_tooltip = $self->get_update_details_tooltip( $tooltip_name, $allele_designations->{$locus} );
				$locus_value .=
				  "<span style=\"font-size:0.5em\"> </span><a class=\"update_tooltip\" title=\"$update_tooltip\">&nbsp;...&nbsp;</a>";
			}
		}
		$locus_value .= $self->get_seq_detail_tooltips( $isolate_id, $locus ) if $self->{'prefs'}->{'sequence_details'};
		if ( $allele_designations->{$locus}->{'allele_id'} ) {
			$locus_value .= $self->_get_pending_designation_tooltip( $isolate_id, $locus ) || '';
		}
		my $action = $allele_designations->{$locus}->{'allele_id'} ? 'update' : 'add';
		$locus_value .=
		    " <a href=\"$self->{'system'}->{'script_name'}?page=alleleUpdate&amp;db=$self->{'instance'}&amp;"
		  . "isolate_id=$isolate_id&amp;locus=$locus\" class=\"update\">$action</a>"
		  if $self->{'curate'};
		my $cleaned   = $self->clean_locus($locus);
		my $dt_buffer = "<dt>$cleaned";
		my @other_display_names;
		if ( $locus_aliases->{$locus} ) {
			push @other_display_names, @{ $locus_aliases->{$locus} };
		}
		local $" = ';nbsp';
		my $alias_display = $self->{'prefs'}->{'locus_alias'} ? 'inline' : 'none';
		$dt_buffer .= "&nbsp;<span class=\"aliases\" style=\"display:$alias_display\">(@other_display_names)</span>"
		  if @other_display_names;
		if ( $locus_info->{'description_url'} ) {
			$locus_info->{'description_url'} =~ s/\&/\&amp;/g;
			$dt_buffer .= "&nbsp;<a href=\"$locus_info->{'description_url'}\" class=\"info_tooltip\">&nbsp;<i>i</i>&nbsp;</a>";
		}
		$dt_buffer .= "</dt>\n";
		my $dd_buffer;
		$locus_value = '&nbsp' if $locus_value eq '';
		$dd_buffer = "<dd>$locus_value</dd>\n";
		my $display_seq =
		  (      $self->{'prefs'}->{'isolate_display_loci'}->{$locus} eq 'sequence'
			  && $allele_designations->{$locus}->{'allele_id'}
			  && !$args->{'summary_view'} )
		  ? 1
		  : 0;
		if ( $display_seq && $allele_designations->{$locus}->{'allele_id'} ) {
			my $sequence;
			try {
				my $sequence_ref =
				  $self->{'datastore'}->get_locus($locus)->get_allele_sequence( $allele_designations->{$locus}->{'allele_id'} );
				$sequence = BIGSdb::Utils::split_line($$sequence_ref);
			}
			catch BIGSdb::DatabaseConnectionException with {
				$sequence = "Can not connect to database";
			}
			catch BIGSdb::DatabaseConfigurationException with {
				my $ex = shift;
				$sequence = $ex->{-text};
			};
			$dd_buffer .= "<dd class=\"seq\">$sequence</dd>\n" if defined $sequence;
		}
		if ($dd_buffer) {
			say "<dl class=\"profile\">$dt_buffer$dd_buffer</dl>";
		}
	}
	my $field_values = $scheme_fields_count ? $self->_get_scheme_field_values( $isolate_id, $scheme_id, $scheme_fields, \@profile ) : undef;
	my $provisional_profile = $self->{'datastore'}->is_profile_provisional( $scheme_id, \@profile, \%provisional_allele );
	foreach my $field (@$scheme_fields) {
		next if !$self->{'prefs'}->{'isolate_display_scheme_fields'}->{$scheme_id}->{$field};
		( my $cleaned = $field ) =~ tr/_/ /;
		say "<dl class=\"profile\">";
		say "<dt>$cleaned</dt>";
		print $provisional_profile ? "<dd><span class=\"provisional\">" : '<dd>';
		print $field_values->{$field} // '-';
		say $provisional_profile ? "</span></dd>" : "</dd>";
		say "</dl>";
	}
	return;
}

sub _get_pending_designation_tooltip {
	my ( $self, $isolate_id, $locus ) = @_;
	my $buffer;
	my $pending = $self->{'datastore'}->get_pending_allele_designations( $isolate_id, $locus );
	my $pending_buffer;
	if (@$pending) {
		$pending_buffer = 'pending designations - ';
		foreach (@$pending) {
			my $sender = $self->{'datastore'}->get_user_info( $_->{'sender'} );
			$pending_buffer .= "allele: $_->{'allele_id'} ";
			$pending_buffer .= "($_->{'comments'}) " if $_->{'comments'};
			$pending_buffer .= "[$sender->{'first_name'} $sender->{'surname'}; $_->{'method'}; $_->{'datestamp'}]<br />";
		}
	}
	$buffer .= "<span style=\"font-size:0.2em\"> </span><a class=\"pending_tooltip\" title=\"$pending_buffer\">pending</a>"
	  if $pending_buffer && $self->{'prefs'}->{'display_pending'};
	return $buffer;
}

sub get_title {
	my ($self)     = @_;
	my $q          = $self->{'cgi'};
	my $isolate_id = $q->param('id');
	return '' if defined $q->param('scheme_id') || defined $q->param('group_id');
	return "Invalid isolate id" if !BIGSdb::Utils::is_int($isolate_id);
	my @name  = $self->get_name($isolate_id);
	my $title = "Isolate information: id-$isolate_id";
	local $" = ' ';
	$title .= " (@name)" if $name[1];
	$title .= ' - ';
	$title .= "$self->{'system'}->{'description'}";
	return $title;
}

sub _get_history {
	my ( $self, $isolate_id, $limit ) = @_;
	my $limit_clause = $limit ? " LIMIT $limit" : '';
	my $count;
	my $history =
	  $self->{'datastore'}
	  ->run_list_query_hashref( "SELECT timestamp,action,curator FROM history where isolate_id=? ORDER BY timestamp desc$limit_clause",
		$isolate_id );
	if ($limit) {    #need to count total
		$count = $self->{'datastore'}->run_simple_query( "SELECT COUNT(*) FROM history WHERE isolate_id=?", $isolate_id )->[0];
	} else {
		$count = @$history;
	}
	return $history, $count;
}

sub get_name {
	my ( $self, $isolate_id ) = @_;
	return if $self->{'system'}->{'dbtype'} ne 'isolates';
	my $name_ref =
	  $self->{'datastore'}
	  ->run_simple_query( "SELECT $self->{'system'}->{'labelfield'} FROM $self->{'system'}->{'view'} WHERE id=?", $isolate_id );
	if ( ref $name_ref eq 'ARRAY' ) {
		return ( $self->{'system'}->{'labelfield'}, $name_ref->[0] );
	}
	return;
}

sub _get_ref_links {
	my ( $self, $isolate_id ) = @_;
	my $pmids =
	  $self->{'datastore'}->run_list_query( "SELECT refs.pubmed_id FROM refs WHERE isolate_id=? ORDER BY pubmed_id", $isolate_id );
	return $self->get_refs($pmids);
}

sub get_refs {
	my ( $self, $pmids ) = @_;
	my $buffer = '';
	if (@$pmids) {
		$buffer .= "<h2>Publication" . ( @$pmids > 1 ? 's' : '' ) . " (" . @$pmids . ")";
		my $display = @$pmids > 4 ? 'none' : 'block';
		$buffer .=
"<span style=\"margin-left:1em\"><a id=\"show_refs\" class=\"smallbutton\" style=\"cursor:pointer\">&nbsp;show/hide&nbsp;</a></span>"
		  if $display eq 'none';
		$buffer .= "</h2>\n";
		my $id = $display eq 'none' ? 'hidden_references' : 'references';
		$buffer .= "<ul id=\"$id\">\n";
		my $citations =
		  $self->{'datastore'}
		  ->get_citation_hash( $pmids, { formatted => 1, all_authors => 1, state_if_unavailable => 1, link_pubmed => 1 } );
		foreach my $pmid ( sort { $citations->{$a} cmp $citations->{$b} } @$pmids ) {
			$buffer .= "<li style=\"padding-bottom:1em\">$citations->{$pmid}";
			$buffer .= $self->get_link_button_to_ref($pmid);
			$buffer .= "</li>\n";
		}
		$buffer .= "</ul>\n";
	}
	return $buffer;
}

sub _get_seqbin_link {
	my ( $self, $isolate_id ) = @_;
	my $seqbin_count = $self->{'datastore'}->run_simple_query( "SELECT COUNT(*) FROM sequence_bin WHERE isolate_id=?", $isolate_id )->[0];
	my $buffer       = '';
	my $q            = $self->{'cgi'};
	if ($seqbin_count) {
		my $length_data =
		  $self->{'datastore'}->run_simple_query(
			"SELECT SUM(length(sequence)), CEIL(AVG(length(sequence))), MAX(length (sequence)) FROM sequence_bin WHERE isolate_id=?",
			$isolate_id );
		my $plural = $seqbin_count == 1 ? '' : 's';
		$buffer .= "<h2>Sequence bin</h2>\n";
		$buffer .= "<div id=\"seqbin\">";
		$buffer .= "<dl class=\"data\">\n";
		$buffer .= "<dt class=\"dontend\">contigs</dt>\n";
		$buffer .= "<dd>$seqbin_count</dd>\n";
		if ( $seqbin_count > 1 ) {
			my $lengths =
			  $self->{'datastore'}
			  ->run_list_query( "SELECT length(sequence) FROM sequence_bin WHERE isolate_id=? ORDER BY length(sequence) DESC",
				$isolate_id );
			my $n_stats = BIGSdb::Utils::get_N_stats( $length_data->[0], $lengths );
			$buffer .= "<dt class=\"dontend\">total length</dt><dd>$length_data->[0] bp</dd>\n";
			$buffer .= "<dt class=\"dontend\">max length</dt><dd>$length_data->[2] bp</dd>\n";
			$buffer .= "<dt class=\"dontend\">mean length</dt><dd>$length_data->[1] bp</dd>\n";
			$buffer .= "<dt class=\"dontend\">N50</dt><dd>$n_stats->{'N50'}</dd>\n";
			$buffer .= "<dt class=\"dontend\">N90</dt><dd>$n_stats->{'N90'}</dd>\n";
			$buffer .= "<dt class=\"dontend\">N95</dt><dd>$n_stats->{'N95'}</dd>\n";
		} else {
			$buffer .= "<dt class=\"dontend\">length</dt>\n";
			$buffer .= "<dd>$length_data->[0] bp</dd>\n";
		}
		my $set_id = $self->get_set_id;
		my $set_clause =
		  $set_id
		  ? "AND (locus IN (SELECT locus FROM scheme_members WHERE scheme_id IN (SELECT scheme_id FROM set_schemes "
		  . "WHERE set_id=$set_id)) OR locus IN (SELECT locus FROM set_loci WHERE set_id=$set_id))"
		  : '';
		my $tagged = $self->{'datastore'}->run_simple_query(
			"SELECT COUNT(DISTINCT locus) FROM allele_sequences LEFT JOIN sequence_bin ON allele_sequences.seqbin_id = sequence_bin.id "
			  . "WHERE sequence_bin.isolate_id=? $set_clause",
			$isolate_id
		)->[0];
		$plural = $tagged == 1 ? 'us' : 'i';
		$buffer .= "<dt class=\"dontend\">loci tagged</dt><dd>$tagged</dd>\n";
		$buffer .= "<dt class=\"dontend\">detailed breakdown</dt><dd>";
		$buffer .= $q->start_form;
		$q->param( 'curate', 1 ) if $self->{'curate'};
		$q->param( 'page', 'seqbin' );
		$q->param( 'isolate_id', $isolate_id );
		$buffer .= $q->hidden($_) foreach qw (db page curate isolate_id);
		$buffer .= $q->submit( -value => 'Display', -class => 'smallbutton' );
		$buffer .= $q->end_form;
		$buffer .= "</dd></dl>\n";
		$q->param( 'page', 'info' );
		$buffer .= "</div>";
	}
	return $buffer;
}

sub _print_projects {
	my ( $self, $isolate_id ) = @_;
	my $projects = $self->{'datastore'}->run_list_query_hashref(
		"SELECT * FROM projects WHERE full_description IS NOT NULL AND id IN "
		  . "(SELECT project_id FROM project_members WHERE isolate_id=?) ORDER BY id",
		$isolate_id
	);
	if (@$projects) {
		say "<div class=\"box\" id=\"projects\"><div class=\"scrollable\">";
		say "<h2>Projects</h2>";
		my $plural = @$projects == 1 ? '' : 's';
		say "<p>This isolate is a member of the following project$plural:</p>";
		say "<dl class=\"projects\">";
		foreach my $project (@$projects) {
			say "<dt>$project->{'short_description'}</dt>";
			say "<dd>$project->{'full_description'}</dd>";
		}
		say "</dl></div></div>";
	}
	return;
}
1;
