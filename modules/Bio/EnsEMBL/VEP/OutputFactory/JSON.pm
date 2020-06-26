=head1 LICENSE

Copyright [2016-2020] EMBL-European Bioinformatics Institute

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

   http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

=cut


=head1 CONTACT

 Please email comments or questions to the public Ensembl
 developers list at <http://lists.ensembl.org/mailman/listinfo/dev>.

 Questions may also be sent to the Ensembl help desk at
 <http://www.ensembl.org/Help/Contact>.

=cut

# EnsEMBL module for Bio::EnsEMBL::VEP::OutputFactory::JSON
#
#

=head1 NAME

Bio::EnsEMBL::VEP::OutputFactory::JSON - JSON format output factory

=head1 SYNOPSIS

my $of = Bio::EnsEMBL::VEP::OutputFactory::JSON->new({
  config => $config,
});

# print output
print "$_\n" for @{$of->get_all_lines_by_InputBuffer($ib)};

=head1 DESCRIPTION

An OutputFactory class to generate JSON output. This is used
by the REST API to retrieve hashrefs structured ready to be
returned as JSON, but also can be used as an output format by
script users.

It differs significantly in its structure from the other output
formats in that each line or hashref returned contains the data
for *all* allele/feature overlaps for the variant along with any
locus-specific data.

This is somewhat more efficient in that data is not duplicated
between lines or blocks as with the other output formats, but
loses efficiency as each data point has a key that is repeated
for each variant.

It does offer significant advantages in the representation of
more structured data, as the JSON format allows as many layers of
depth as required to represent the data.

This different structure is also apparent in the structure of the
API calls as executed here; the way they are separated in the parent
OutputFactory class largely assists their reimplementation in this
class.

=head1 METHODS

=cut


use strict;
use warnings;

package Bio::EnsEMBL::VEP::OutputFactory::JSON;

use base qw(Bio::EnsEMBL::VEP::OutputFactory);

use Bio::EnsEMBL::Utils::Exception qw(throw warning);
use Bio::EnsEMBL::Variation::Utils::Constants;

use Bio::EnsEMBL::VEP::Utils qw(numberify);

use JSON;
use Scalar::Util qw(looks_like_number);

my %SKIP_KEYS = (
  'Uploaded_variation' => 1,
  'Location' => 1,
);

my %RENAME_KEYS = (
  'consequence' => 'consequence_terms',
  'gene' => 'gene_id',
  'allele' => 'variant_allele',
  'symbol' => 'gene_symbol',
  'symbol_source' => 'gene_symbol_source',
  'overlapbp' => 'bp_overlap',
  'overlappc' => 'percentage_overlap',
  'refseq' => 'refseq_transcript_ids',
  'ensp' => 'protein_id',
  'chr' => 'seq_region_name',
  'variation_name' => 'id',
  'sv' => 'colocated_structural_variants',
);

my %NUMBERIFY_EXEMPT = (
  'seq_region_name' => 1,
  'id' => 1,
  'gene_id' => 1,
  'gene_symbol' => 1,
  'transcript_id' => 1,
);

my @LIST_FIELDS = qw(
  clin_sig
  pubmed
);


=head2 new

  Arg 1      : hashref $args
  Example    : $of = Bio::EnsEMBL::VEP::OutputFactory::JSON->new({
                 config => $config,
               });
  Description: Creates a new Bio::EnsEMBL::VEP::OutputFactory::JSON object.
               Has its own constructor to add several params via
               add_shortcuts()
  Returntype : Bio::EnsEMBL::VEP::OutputFactory::JSON
  Exceptions : none
  Caller     : Runner
  Status     : Stable

=cut

sub new {
  my $caller = shift;
  my $class = ref($caller) || $caller;
  
  my $self = $class->SUPER::new(@_);
  $self->{af_1kg} = 1;
  $self->{af_esp} = 1;
  $self->{af_gnomad} = 1;
  $self->{af_exac} = 1;

  # add shortcuts to these params
  $self->add_shortcuts([qw(
    assembly
    cache_assembly
    delimiter
  )]);

  $self->{delimiter} = " " if $self->{delimiter} =~ /\+/;

  return $self;
}


=head2 output_hash_to_line

  Arg 1      : hashref $vf_hash
  Example    : $line = $of->output_hash_to_line($vf_hash);
  Description: Takes a hashref as generated by get_all_output_hashes_by_InputBuffer
               and returns a JSON-encoded string ready for printing.
  Returntype : string
  Exceptions : none
  Caller     : get_all_lines_by_InputBuffer()
  Status     : Stable

=cut

sub output_hash_to_line {
  my $self = shift;
  my $hash = shift;

  $self->{json_obj} ||= JSON->new;
  return $self->{json_obj}->encode($hash);
}


=head2 get_all_output_hashes_by_InputBuffer

  Arg 1      : Bio::EnsEMBL::VEP::InputBuffer $ib
  Example    : $hashes = $of->get_all_output_hashes_by_InputBuffer($ib);
  Description: Gets all hashrefs of data given an annotated input buffer.
               One hashref corresponds to one variant.
  Returntype : arrayref of hashrefs
  Exceptions : none
  Caller     : get_all_lines_by_InputBuffer(), Runner
  Status     : Stable

=cut

sub get_all_output_hashes_by_InputBuffer {
  my $self = shift;
  my $buffer = shift;

  map {@{$self->reset_shifted_positions($_)}}
    @{$buffer->buffer};

  $self->rejoin_variants_in_InputBuffer($buffer) if $buffer->rejoin_required;

  my @return;

  foreach my $vf(@{$buffer->buffer}) {

    my $hash = {
      id              => $vf->{variation_name},
      seq_region_name => $vf->{chr},
      start           => $vf->{start},
      end             => $vf->{end},
      strand          => $vf->{strand},
      allele_string   => $vf->{allele_string} || $vf->{class_SO_term},
      assembly_name   => $self->{assembly} || $self->{cache_assembly},
      # _order        => $vf->{_order},
    };

    # add original input for use by POST endpoints
    $hash->{input} = join($self->{delimiter}, @{$vf->{_line}}) if defined($vf->{_line});

    # add custom annotations here and delete so they don't get added again
    $hash->{custom_annotations} = delete($vf->{_custom_annotations}) if $vf->{_custom_annotations};

    # get other data from super methods
    my $extra_hash = $self->VariationFeature_to_output_hash($vf);
    $hash->{lc($_)} = $extra_hash->{$_} for grep {!$SKIP_KEYS{$_}} keys %$extra_hash;

    $self->add_VariationFeatureOverlapAllele_info($vf, $hash);

    # rename
    my %rename = %RENAME_KEYS;
    foreach my $key(grep {defined($hash->{$_})} keys %rename) {
      $hash->{$rename{$key}} = $hash->{$key};
      delete $hash->{$key};
    }

    # get all alleles and remove ref allele
    my $allele_string = $hash->{allele_string};
    my @alleles = split('/', $allele_string);
    shift @alleles;

    foreach my $ex_orig(@{$vf->{existing} || []}) {
      my @allele_frequency_hashes = ();
      foreach my $allele (@alleles) {
        my $frequency_hash = {Allele => $allele};
        $self->SUPER::add_colocated_frequency_data($vf, $frequency_hash, $ex_orig);
        push @allele_frequency_hashes, $frequency_hash;
      }
      $self->add_colocated_variant_info_JSON($hash, \@allele_frequency_hashes, $ex_orig);
    }

    numberify($hash, \%NUMBERIFY_EXEMPT);

    push @return, $hash;
  }

  return \@return;
}


=head2 add_VariationFeatureOverlapAllele_info

  Arg 1      : Bio::EnsEMBL::Variation::VariationFeature $vf
  Arg 2      : hashref $vf_hash
  Example    : $vf_hash = $of->add_VariationFeatureOverlapAllele_info($vf, $vf_hash);
  Description: Formats and adds consequence data retrieved via
               get_all_VariationFeatureOverlapAllele_output_hashes() to the hashref
  Returntype : arrayref of hashrefs
  Exceptions : none
  Caller     : get_all_output_hashes_by_InputBuffer()
  Status     : Stable

=cut

sub add_VariationFeatureOverlapAllele_info {
  my $self = shift;
  my $vf = shift;
  my $hash = shift;

  # record all cons terms so we can get the most severe
  my @con_terms;

  # add consequence stuff
  foreach my $vfoa_hash(@{$self->get_all_VariationFeatureOverlapAllele_output_hashes($vf, {})}) {

    # lc and remove empty
    foreach my $key(keys %$vfoa_hash) {
      my $tmp = $vfoa_hash->{$key};
      delete $vfoa_hash->{$key};

      next if !defined($tmp) || ($key ne 'Allele' && $tmp eq '-');

      # convert YES to 1
      $tmp = 1 if $tmp eq 'YES';

      # fix position fields into start and end
      if($key =~ /(\w+?)\_position$/i) {
        my $coord_type = lc($1);
        my ($s, $e) = split('-', $tmp);
        $vfoa_hash->{$coord_type.'_start'} = $s;
        $vfoa_hash->{$coord_type.'_end'} = defined($e) && $e =~ /^\d+$/ ? $e : $s;

        # on rare occasions coord can be "?"; for now just don't print anything
        delete $vfoa_hash->{$coord_type.'_start'} unless looks_like_number($vfoa_hash->{$coord_type.'_start'});
        delete $vfoa_hash->{$coord_type.'_end'}   unless looks_like_number($vfoa_hash->{$coord_type.'_end'});
        next;
      }

      $vfoa_hash->{lc($key)} = $tmp;
    }

    my $ftype = lc($vfoa_hash->{feature_type} || 'intergenic');
    $ftype =~ s/feature/\_feature/;
    delete $vfoa_hash->{feature_type};

    # fix SIFT and PolyPhen
    foreach my $tool(qw(sift polyphen)) {
      if(defined($vfoa_hash->{$tool}) && $vfoa_hash->{$tool} =~ m/([a-z\_]+)?\(?([\d\.]+)?\)?/i) {
        my ($pred, $score) = ($1, $2);
        $vfoa_hash->{$tool.'_prediction'} = $pred if $pred;
        $vfoa_hash->{$tool.'_score'} = $score if defined($score);
        delete $vfoa_hash->{$tool};
      }
    }

    # fix domains
    if(defined($vfoa_hash->{domains})) {
      my @dom;

      foreach(@{$vfoa_hash->{domains}}) {
        m/(\w+)\:(\w+)/;
        push @dom, {"db" => $1, "name" => $2} if $1 && $2;
      }
      $vfoa_hash->{domains} = \@dom;
    }

    # log observed consequence terms
    push @con_terms, @{$vfoa_hash->{consequence}};

    # rename
    my %rename = %RENAME_KEYS;

    $rename{feature} = lc($ftype).'_id';
    foreach my $key(grep {defined($vfoa_hash->{$_})} keys %rename) {
      $vfoa_hash->{$rename{$key}} = $vfoa_hash->{$key};
      delete $vfoa_hash->{$key};
    }

    push @{$hash->{$ftype.'_consequences'}}, $vfoa_hash;
  }

  my %all_cons = %Bio::EnsEMBL::Variation::Utils::Constants::OVERLAP_CONSEQUENCES;
  $hash->{most_severe_consequence} = (sort {$all_cons{$a}->rank <=> $all_cons{$b}->rank} grep {$_ ne '?'} @con_terms)[0] || '?';

  return $hash;
}


=head2 add_colocated_variant_info

  Arg 1      : Bio::EnsEMBL::Variation::VariationFeature $vf
  Arg 2      : arrayref of hashref $frequency_hashes
  Example    : $hashref = $of->add_colocated_variant_info($vf, $frequency_hashes);
  Description: Adds co-located variant information to hash
  Returntype : hashref
  Exceptions : none
  Caller     : VariationFeature_to_output_hash()
  Status     : Stable

=cut

sub add_colocated_variant_info_JSON {
  my $self = shift;
  my $hash = shift;
  my $frequency_hashes = shift;
  my $ex_orig = shift;
  
  # work on a copy as we're going to modify/delete things
  my $ex;
  %$ex = %$ex_orig;

  delete $ex->{$_} for qw(failed matched_alleles);
 
  my $frequencies = {};
  foreach my $frequency_hash (@$frequency_hashes) {
    my $allele = $frequency_hash->{Allele};
    # frequencies
    foreach my $pop (grep {defined($frequency_hash->{"$_\_AF"})} qw(
      AFR AMR ASN EAS SAS EUR
      AA EA
      ExAC ExAC_Adj ExAC_AFR ExAC_AMR ExAC_EAS ExAC_FIN ExAC_NFE ExAC_OTH ExAC_SAS
      gnomAD gnomAD_AFR gnomAD_AMR gnomAD_ASJ gnomAD_EAS gnomAD_FIN gnomAD_NFE gnomAD_OTH gnomAD_SAS
    )) {
      my $lc_pop = lc($pop);
      $frequencies->{$allele}->{$lc_pop} = $frequency_hash->{"$pop\_AF"}[0];
      delete $ex->{$pop};
    }
  }
 
  $ex->{frequencies} = $frequencies if (keys %$frequencies);
  # remove empty
  foreach my $key(keys %$ex) {
    delete $ex->{$key} if !defined($ex->{$key}) || $ex->{$key} eq '' || ($key !~ /af/ && $ex->{$key} eq 0);
  }

  # rename
  foreach my $key(grep {defined($ex->{$_})} keys %RENAME_KEYS) {
    $ex->{$RENAME_KEYS{$key}} = $ex->{$key};
    delete $ex->{$key};
  }

  # lists
  foreach my $field(grep {defined($ex->{$_})} @LIST_FIELDS) {
    $ex->{$field} = [split(',', $ex->{$field})];
  }

  # update variation synonyms
  if(defined($ex->{var_synonyms})){
    my $var_syn_hash;
    my @str = split /--/, $ex->{var_synonyms};
    foreach my $source (@str){
      my @spl = split /::/, $source;
      my @output = split /,/, $spl[1];
      $var_syn_hash->{$spl[0]} = \@output;
    }

    $ex->{var_synonyms} = $var_syn_hash;
  }

  push @{$hash->{colocated_variants}}, $ex;

  return $hash;
}


=head2 add_colocated_variant_info

  Arg 1      : Bio::EnsEMBL::Variation::VariationFeature $vf
  Arg 2      : hashref $vf_hash
  Example    : $hashref = $of->add_colocated_variant_info($vf, $vf_hash, $ex);
  Description: Just a stub; colocated data is added by add_colocated_variant_info_JSON()
               in this class.
  Returntype : hashref
  Exceptions : none
  Caller     : VariationFeatureOverlapAllele_to_output_hash()
  Status     : Stable

=cut

sub add_colocated_variant_info {
  return $_[1];
}


=head2 add_colocated_frequency_data

  Arg 1      : Bio::EnsEMBL::Variation::VariationFeature $vf
  Arg 2      : hashref $vf_hash
  Arg 3      : hashref $existing_variant_hash
  Example    : $hashref = $of->add_colocated_frequency_data($vf, $vf_hash, $ex);
  Description: Just a stub; frequency data is added by add_colocated_variant_info()
               in this class.
  Returntype : hashref
  Exceptions : none
  Caller     : VariationFeatureOverlapAllele_to_output_hash()
  Status     : Stable

=cut

sub add_colocated_frequency_data {
  return $_[1];
}

1;
