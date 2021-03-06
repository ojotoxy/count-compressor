#!/usr/bin/perl -w

use strict;

use Data::Dumper;

#use Digest::SHA qw(sha256);
use Digest::MD5 qw(md5_base64 md5);
#use Data::UUID;

#my $ug    = new Data::UUID;
use Storable qw(store_fd nstore_fd freeze thaw);

use JSON::XS;

use count;

my %field_names;
my $predictor_string;
my @column_encodings;
my $driving_column = -1;
eval `cat regular_count_config.pl` or die "Error reading config file: $!";


my @predictors=map {my ($l,$r)=split /=>/, $_; ([grep {$_} (split /\s+/, $l)],[grep {$_} (split /\s+/, $r)])} (grep {$_ =~ /=>/} (map {s/#.+$//;$_} (split /\n/, $predictor_string)));

#warn Dumper \@predictors;

my %field_name_to_col = map { $field_names{$_} => $_} keys %field_names;

warn Dumper \%field_name_to_col;

#exit;



my @predictor_cols;

my %col_to_predicted_cols;

my @col_is_used_as_a_predictor;
my @col_can_ever_be_predicted;

for (my $i=0; $i<= $#predictors/2; $i++){

    my $left = join '-', map {$field_name_to_col{$_}} @{$predictors[2*$i]};
    $left .=sprintf("_%03d",$i);
    map {$col_is_used_as_a_predictor[$field_name_to_col{$_}] = 1} @{$predictors[2*$i]};
    die "A lower level predictor CANNOT predict the driving column of a higher level one." if grep {$col_is_used_as_a_predictor[$_] } (map {$field_name_to_col{$_}} @{$predictors[2*$i+1]});
    push @predictor_cols, $left;
    $col_to_predicted_cols{$left} = [sort {$a <=> $b} map {$field_name_to_col{$_}} @{$predictors[2*$i+1]}];
    map {$col_can_ever_be_predicted[$field_name_to_col{$_}] = 1} @{$predictors[2*$i+1]};
}

my @sort_order;
# for (my $c=0;$c<$n_cols;$c++){
#     if($col_is_used_as_a_predictor[$c]){
#         push @sort_order, $c;
#     }
# }

#@sort_order = map {$field_name_to_col{$_}} qw(ip uuid sid datetime);


#warn Dumper \@col_can_ever_be_predicted;exit;

my $i=0;

my @fields_to_vals;

my @fields_to_char_to_pop;

my @fields_to_val_to_last_seen;

my @records;

my $bytes_read=0;

open INPUT_SAVE, ">INPUT_SAVE";

my $n_cols=0;






my @col_to_max_length;

my $rows_sum=0;

while(<>){
    $i++;
    $bytes_read += length($_);
    #print INPUT_SAVE $_;
    chomp;
    my @fields = split /\t/;


    $n_cols = $#fields+1 if $#fields+1 > $n_cols;


    #DESTRUCTIVE ROW MODIFICATIONS
    for(my $c=0;$c<=$#fields;$c++){
        $column_encodings[$c]='' unless defined $column_encodings[$c];
        if($column_encodings[$c] eq 'uuid'){
            my $uuid = $fields[$c];
            warn "BAD UUID '$uuid' " unless lc $uuid eq  lc count::uuid_unbinarize(count::uuid_binarize($uuid));
            $uuid = count::shorten_uuid($uuid);
            $fields[$c] = $uuid;
        }
        if($column_encodings[$c] eq 'datetime'){
            $fields[$c] = count::chop_seconds_from_datetime($fields[$c]);
        }
        if($column_encodings[$c] eq 'ignore'){
            $fields[$c] = '';
        }
    }



    #DONE MODIFYING ROW
    my $row_string = join "\t", @fields;
    #$rows_sum += count::str2num(substr(md5($row_string),0,3));#first 3 bytes of md5 sum
    $rows_sum += (count::jenkins_hash_unmodified($row_string) & ((2**24)-1));


    print INPUT_SAVE ($row_string."\n");

    #NON-DESTRUCTIVE Row Encodings
    for(my $c=0;$c<=$#fields;$c++){
        if($column_encodings[$c] eq 'ip'){
            my $ip = $fields[$c];
            warn "BAD IP '$ip'" unless $ip eq count::ip_unbinarize(count::ip_binarize $ip);
            $fields[$c]=count::ip_binarize $ip;
        }
        if($column_encodings[$c] eq 'uuid'){
            $fields[$c] = count::short_uuid_binarize($fields[$c]);
        }
        if($column_encodings[$c] eq 'datetime'){
            my $datetime = $fields[$c];
            my $int =  count::datetime_to_integer $datetime;
            my $d = count::datetime_from_integer $int;
            $fields[$c]=$int;
            warn "$datetime\t$d\t$int\n" unless $datetime eq $d;
        }
    }




    #print Dumper \@fields;
    for(my $c=0;$c<=$#fields;$c++){

        $fields_to_vals[$c]->{$fields[$c]}++;

        $col_to_max_length[$c] = 0 unless $col_to_max_length[$c];
        $col_to_max_length[$c] = length($fields[$c]) if length($fields[$c]) > $col_to_max_length[$c];
    }

    push @records, \@fields;



    last if $i==100000;

}

#warn Dumper \@col_to_max_length;
my @unpredictable_cols;
my @col_to_uniques;
for (my $c=0;$c<$n_cols;$c++){
    $col_to_uniques[$c]=scalar (keys %{$fields_to_vals[$c]});
    #push @unpredictable_cols, $c unless

    warn "col\t$c\t$col_to_uniques[$c] uniques\n";

}


push @sort_order, $driving_column if $driving_column >=0;
push @sort_order, sort {$col_to_uniques[$b] <=> $col_to_uniques[$a]} (grep {$_ != $driving_column}  0..($n_cols-1));

warn Dumper \@sort_order;

my $sort_function = join " or ", (map {"(\$a->[$_] cmp \$b->[$_])"} @sort_order);

#warn $sort_function;

eval "\@records = sort {$sort_function} \@records";
die "sort eval error: $@" if $@;



my $driving_column_uniques = $col_to_uniques[$driving_column];
warn "$driving_column_uniques driving column uniques\n";

my $driving_column_size = $col_to_max_length[$driving_column];
my $driving_col_rice_bits = count::rice_bits($driving_column_size*8, $driving_column_uniques);
warn "$driving_col_rice_bits driving column rice bits\n";

for (my $c=0;$c<$n_cols;$c++){

    for my $val (keys %{$fields_to_vals[$c]}){
        for my $char(split //, $val){
            $fields_to_char_to_pop[$c]->{$char}++;
        }
    }

}

for (my $r=0;$r<=$#records;$r++){
    my $record = $records[$r];
    for (my $c=0;$c<$n_cols;$c++){
        $fields_to_val_to_last_seen[$c]->{$record->[$c]}=$r unless ($r!=0 and $records[$r-1]->[$c] eq $record->[$c]);
    }
}

my @col_is_numeric;

my @col_to_sorted_keys;

my @col_to_val_to_key_idx;

my @col_to_bits;

my @col_to_alphabet;



for (my $c=0;$c<$n_cols;$c++){
    my $is_numeric=1;
    my @sorted_keys = sort {$fields_to_vals[$c]->{$b} cmp $fields_to_vals[$c]->{$a}} keys %{$fields_to_vals[$c]};
    $col_to_sorted_keys[$c]=\@sorted_keys;

    my $n_keys = $#sorted_keys+1;
    my $bits_for_col = count::log2_int($n_keys-1);
    $col_to_bits[$c]=$bits_for_col;
    my %val_to_key_idx;
    my $i=0;
    for my $val (@sorted_keys){
        $val_to_key_idx{$val}=$i;

        if($is_numeric and $val =~ /\D/){
            $is_numeric=0;
        }
        $i++;
    }
    #warn "col $c is numeric: $is_numeric\n";
    $col_is_numeric[$c]=$is_numeric;
    $col_to_val_to_key_idx[$c]=\%val_to_key_idx;

    my @used_chars = keys %{$fields_to_char_to_pop[$c]};

    if($#used_chars <= 128){
        @used_chars = sort {$fields_to_char_to_pop[$c]->{$b} <=> $fields_to_char_to_pop[$c]->{$a}} @used_chars;

        $col_to_alphabet[$c]=join '', @used_chars;

    }



}

open BINARY, ">BINARY";
open BINARY2, ">BINARY2";
open INDEX, ">INDEX";




# my @encoding_files;
# my @lit_length_files;
# my @literal_files;
# my @reference_files;
# for (my $c=0;$c<$n_cols;$c++){
#     open my $c1, '>', "OFILES2/encoding_$c" or die "cant open: $@";
#     open my $c2, '>', "OFILES2/lit_length_$c" or die "cant open: $@";
#     open my $c3, '>', "OFILES2/literal_$c" or die "cant open: $@";
#     open my $c4, '>', "OFILES2/reference_$c" or die "cant open: $@";
#
#     $encoding_files[$c]=$c1;
#     $lit_length_files[$c]=$c2;
#     $literal_files[$c]=$c3;
#     $reference_files[$c]=$c4;
# }
#
# open my $predictor_file, '>', "OFILES2/predictors" or die "cant open: $@";

#record format
# which columns are being used to make predictions + what is is being used to predict? (both inner and outer lists skip entries that offer no new prediction potential). No circular references.
#BYTE BOUNDARY
# for each column that is not predicted,
#   an encoded value.

#possible ways to encode a value that can't be predicted
#length limited literal with column's alphabet and add to store
#length limited literal with column's alphabet and Don't add
#refer to previous value, nth stored
#refer to previous value, nth stored AND delete from stored list
#copy from above

#dont store very short values, or values that are only seen once.

#CURRENT CHOICES:
# 0 - Use stored value
# 1 - Use Literal value, add to store


#SECOND BIT CHOICES:
# 0 - Delete / Don't store
# 1 - Keep in store


my @col_to_currently_stored_val_list;
my @col_to_currently_stored_val_hash;

my %col_to_value_to_friends_str_to_count;
my %col_to_value_to_most_popular_friends;

my %col_to_friends_str_to_count;
my %col_to_most_popular_friends;



my @col_to_last_ref_idx;
my @col_to_ref_sum;
my @col_to_ref_count;


my $rows_with_deletes=0;
my $rows_with_copies=0;
my $rows_with_refs=0;
my $rows_with_lits=0;
my $rows_using_a_predictor=0;

for (my $r=0;$r<=$#records;$r++){

    my $record = $records[$r];
    my $row_encoding_has_a_delete=0;
    my $row_encoding_has_a_copy=0;
    my $row_encoding_has_a_ref=0;
    my $row_encoding_has_a_lit=0;
    my $row_encoding_uses_predictor=0;
    my $bitstring='';



    my $row_header_bits='';
    my $row_value_bits='';
    my $row_lit_length_bits='';


    my $dupes=0;
    my $matches=1;
    for (my $rr=$r+1;$rr<=$#records;$rr++){
        my $rrecord = $records[$rr];
        my $row_matches=1;
        for (my $c=0;$c<$n_cols;$c++){
            if($record->[$c] ne $rrecord->[$c]){
                $row_matches=0;
                last;
            }
        }
        if($row_matches){
            $dupes++;
        }else{
            last;
        }
    }






    my %predictor_col_used;
    my %col_was_predicted;

    my $predictor_bits='';

    my $encoding_list='';

    for my $ceez(@predictor_cols){

        #check if you need to store a predictor used bit. if everything it would have predicted is already predicted, there is no need.
        #if there are no friends for this value, also, no need.
        my $need_predictor_bit=0;
        my @predicted_cols = @{$col_to_predicted_cols{$ceez}};
        CC: for my $cc(@predicted_cols){
            if(not exists $col_was_predicted{$cc}){
                $need_predictor_bit=1;
                last CC;
            }
        }
        if($need_predictor_bit){
            my $predictor_used_bit;

            my @ceez_refers = split /-/, substr($ceez,0,-4);

            my $value = freeze([map {$record->[$_]} @ceez_refers]);

            my $friends_str;
            my $which;
            if(exists $col_to_value_to_most_popular_friends{$ceez}->{$value}){
                $friends_str = $col_to_value_to_most_popular_friends{$ceez}->{$value};
                $which="normal";
            }elsif(exists $col_to_most_popular_friends{$ceez}){
                $friends_str = $col_to_most_popular_friends{$ceez};
                $which = "default";
            }else{

            }

            if(defined $friends_str){
                my @friends = @{thaw $friends_str};
                my $matches=1;
                my $ci=0;
                PREDICTED_COL: for my $cc(@predicted_cols){
                    my $prediction = $friends[$ci];
                    my $actual = $record->[$cc];
                    if($actual ne $prediction){
                        $matches=0;
                        last PREDICTED_COL;
                    }
                    $ci++;
                }
                #predictor match
                if($matches){
                    #warn "predictor match. col $c predicts $#predicted_cols+1 cols...\n";
                    die "LOLWAT" if $r==0;
                    #warn "Ding" if $which eq 'default';
                    #warn " dong" if $which eq 'normal';
                    for my $cc(@predicted_cols){
                        $col_was_predicted{$cc}=1;
                    }
                    $predictor_used_bit='1';
                    $predictor_col_used{$ceez}=1;
                    $row_encoding_uses_predictor=1;
                }else{
                    #predictor non-match
                    #warn "predictor MISMATCH col $c\n";
                    $predictor_used_bit='0';
                }
            }else{
                warn "predictor IMPOSSIBRU\n";
                $predictor_used_bit='0';
            }
            $predictor_bits .= $predictor_used_bit;
        }
    }
    #warn "\n".length($predictor_bits)." predictor bits\n\n";
    #warn Dumper \%predictor_col_used;

    #print $predictor_file count::bitstring_to_bytes($predictor_bits);

    $row_header_bits .= $predictor_bits;

    for my $ceez(@predictor_cols){
        my @ceez_refers = split /-/, substr($ceez,0,-4);

        my $value = freeze([map {$record->[$_]} @ceez_refers]);

        my @friends;
        for my $f(@{$col_to_predicted_cols{$ceez}}){
            push @friends, $record->[$f];
        }
        my $friends_str = freeze(\@friends);
        $col_to_value_to_friends_str_to_count{$ceez}->{$value}->{$friends_str}++;
        my $new_count = $col_to_value_to_friends_str_to_count{$ceez}->{$value}->{$friends_str};
        if((not defined $col_to_value_to_most_popular_friends{$ceez}->{$value}) or ($new_count >= $col_to_value_to_friends_str_to_count{$ceez}->{$value}->{$col_to_value_to_most_popular_friends{$ceez}->{$value}})){
            $col_to_value_to_most_popular_friends{$ceez}->{$value}=$friends_str;
        }

        $col_to_friends_str_to_count{$ceez}->{$friends_str}++;
        $new_count = $col_to_friends_str_to_count{$ceez}->{$friends_str};
        if((not defined $col_to_most_popular_friends{$ceez}) or ($new_count >= $col_to_friends_str_to_count{$ceez}->{$col_to_most_popular_friends{$ceez}})){
            $col_to_most_popular_friends{$ceez}=$friends_str;
        }
    }

    my $encode_col = sub {
        my $c=shift;
        my $val = $record->[$c];
        my $copy_bit=0;
        if($r!=0 and $val eq $records[$r-1]->[$c]){
            $copy_bit=1;
            $row_encoding_has_a_copy=1;
        }
        if($copy_bit){
            $row_header_bits.=$copy_bit;
            $encoding_list .= "COPY  ";
            #print {$encoding_files[0]} count::bitstring_to_bytes($copy_bit);
        }else{

            my $encoding_choice_bit;
            my $value_bits;
            if(exists $col_to_currently_stored_val_hash[$c]->{$val}){
                $encoding_choice_bit=0;
                $encoding_list .= "REF";
                $row_encoding_has_a_ref=1;

                my $last_ref_idx = ($col_to_last_ref_idx[$c] or 1);
                my $ref_idx = $col_to_currently_stored_val_hash[$c]->{$val};
                my $rice_bits = ($col_to_ref_count[$c] and $col_to_ref_sum[$c]) ?
                    count::log2_int(int(($col_to_ref_sum[$c]+$#{$col_to_currently_stored_val_list[$c]})/($col_to_ref_count[$c]+1)))-1
                    : count::log2_int(int(($#{$col_to_currently_stored_val_list[$c]}+1)/2))-1;
                $rice_bits = 0 if $rice_bits < 0;
                $value_bits = count::to_rice($ref_idx, $rice_bits);
                #$value_bits='';
                #warn "col $c used stored val $col_to_currently_stored_val_hash[$c]->{$val} of $#{$col_to_currently_stored_val_list[$c]}\n";

                my $swap_with = int((20*$ref_idx) / 21);

                if($swap_with >= 0 and $swap_with != $ref_idx){
                    my $temp = $col_to_currently_stored_val_list[$c]->[$ref_idx];

                    $col_to_currently_stored_val_list[$c]->[$ref_idx]=$col_to_currently_stored_val_list[$c]->[$swap_with];
                    $col_to_currently_stored_val_list[$c]->[$swap_with]=$temp;

                    $col_to_currently_stored_val_hash[$c]->{$col_to_currently_stored_val_list[$c]->[$ref_idx]}=$ref_idx;
                    $col_to_currently_stored_val_hash[$c]->{$col_to_currently_stored_val_list[$c]->[$swap_with]}=$swap_with;

                }


                $col_to_last_ref_idx[$c]=$ref_idx;
                $col_to_ref_sum[$c]+=$ref_idx;
                $col_to_ref_count[$c]++;
            }else{
                $encoding_choice_bit=1;
                $encoding_list .= "LIT";
                $row_encoding_has_a_lit=1;
                if($c == $driving_column and $r!=0){
                    #only encode the difference

                    $value_bits = count::to_rice(count::str2num($val)-count::str2num($records[$r-1]->[$c]),$driving_col_rice_bits);

                }else{
                    my $xfrm_val=$val;
                    if(defined $col_to_alphabet[$c]){
                        $xfrm_val =~ s/(.)/count::binary_digits(index($col_to_alphabet[$c],$1), count::log2_int(length($col_to_alphabet[$c])-1))/gse;
                        $value_bits=$xfrm_val;
                    }else{
                        $value_bits = count::bytes_to_bitstring($xfrm_val);
                    }
                    $row_lit_length_bits .= count::binary_digits(length($val), count::log2_int($col_to_max_length[$c]));
                }


                #print {$lit_length_files[$c]} count::bitstring_to_bytes(count::binary_digits(length($val), count::log2_int($col_to_max_length[$c])));


                push @{$col_to_currently_stored_val_list[$c]}, $val;
                $col_to_currently_stored_val_hash[$c]->{$val} = $#{$col_to_currently_stored_val_list[$c]};
            }
            my $do_store_bit='';
            if($encoding_choice_bit==1){
                $do_store_bit=0;
                if($fields_to_val_to_last_seen[$c]->{$val} > $r){
                    $do_store_bit=1;
                }
                $encoding_list.= "-$do_store_bit ";
                if($do_store_bit==0){
                    $row_encoding_has_a_delete=1;
                    #warn "DELETING\n";
                    my $delete_idx=$col_to_currently_stored_val_hash[$c]->{$val};
                    splice(@{$col_to_currently_stored_val_list[$c]}, $delete_idx, 1);
                    delete $col_to_currently_stored_val_hash[$c]->{$val};
                    for (my $i=$delete_idx;$i<=$#{$col_to_currently_stored_val_list[$c]};$i++){
                        $col_to_currently_stored_val_hash[$c]->{$col_to_currently_stored_val_list[$c]->[$i]} = $i;
                    }
                }else{
                    #warn "KEEPING\n";
                }
            }
            #$bits = $copy_bit.$encoding_choice_bit.$do_store_bit.$value_bits;

            $row_header_bits.=$copy_bit.$encoding_choice_bit.$do_store_bit;
            $row_value_bits .=$value_bits;
        }

        #$bitstring .= $bits;
    };

    for (my $c=0;$c<$n_cols;$c++){
        next if $col_was_predicted{$c};

        $encode_col->($c);


    }


    if($row_encoding_has_a_delete){
        $rows_with_deletes++;
    }
    if($row_encoding_has_a_copy){
        $rows_with_copies++;
    }
    if($row_encoding_has_a_ref){
        $rows_with_refs++;
    }
    if($row_encoding_has_a_lit){
        $rows_with_lits++;
    }
    if($row_encoding_uses_predictor){
        $rows_using_a_predictor++;
    }
    #warn "row header is".length($row_header_bits)." bits\n";
    #warn "ROW $r: $encoding_list\n";


    $r+=$dupes;

    my $dupes_bits = ('1'x$dupes). '0';

    my $bytes = count::bitstring_to_bytes($row_header_bits).count::bitstring_to_bytes($row_lit_length_bits.$dupes_bits);

    #warn "$n_bits,$bitstring ".length($bytes)." $n_bytes\n" if length($bytes) != $n_bytes;
    #print "$bitstring\n";
    die "too effing long" if length($bytes) > 255;
    #print BINARY chr(length($bytes));
    print BINARY $bytes;
    print BINARY2 count::bitstring_to_bytes($row_value_bits);


}

for (my $c=0;$c<$n_cols;$c++){
    no warnings;
    warn "Col $c: ".($#{$col_to_currently_stored_val_list[$c]}+1)." stored values.\tRefs: $col_to_ref_count[$c]\tAvg ref:".(eval{$col_to_ref_sum[$c]/$col_to_ref_count[$c]})."\n";
}

#warn Dumper \%col_to_value_to_most_popular_friends;

my $col_to_val_plus_friends_uniques;
for my $ceez(@predictor_cols){
    for my $val(keys %{$col_to_value_to_friends_str_to_count{$ceez}}){
        for my $friends(keys %{$col_to_value_to_friends_str_to_count{$ceez}->{$val}}){
            $col_to_val_plus_friends_uniques->{$ceez}++;
        }
    }
}

my $col_to_friends_uniques;
for my $ceez(@predictor_cols){
    $col_to_friends_uniques->{$ceez} = scalar keys(%{$col_to_friends_str_to_count{$ceez}});
}

my $col_to_values_uniques;
for my $ceez(@predictor_cols){
    $col_to_values_uniques->{$ceez} = scalar keys(%{$col_to_value_to_most_popular_friends{$ceez}});
}


warn Dumper $col_to_val_plus_friends_uniques;
warn Dumper $col_to_friends_uniques;
warn Dumper $col_to_values_uniques;

{
    local $Data::Dumper::Indent=0;
    local $Data::Dumper::Terse=1;
    #local $Data::Dumper::Useqq=1;
    local $Data::Dumper::Pair=',';
    local $Data::Dumper::Sortkeys=1;
    print INDEX Dumper {
        #col_to_sorted_keys => \@col_to_sorted_keys,
        n_cols => $n_cols,
        column_encodings => \@column_encodings,
        field_names => \%field_names,
        col_to_predicted_cols => \%col_to_predicted_cols,
        predictor_cols => \@predictor_cols,
        col_to_max_length => \@col_to_max_length,
        col_to_alphabet => \@col_to_alphabet,
        driving_column => $driving_column,
        driving_col_rice_bits => $driving_col_rice_bits,
        rows_sum => $rows_sum,
        n_rows => $#records+1,
        col_to_max_stored_vals => [map {scalar(@{$col_to_currently_stored_val_list[$_]})} (0..($n_cols-1))],
        col_to_uniques => \@col_to_uniques,
        col_to_val_plus_friends_uniques => $col_to_val_plus_friends_uniques,
        col_to_friends_uniques => $col_to_friends_uniques,
        col_to_values_uniques => $col_to_values_uniques,
        };
    #print INDEX encode_json \@col_to_sorted_keys;
    #store_fd \@col_to_sorted_keys, \*INDEX;

}

close INPUT_SAVE;
close INDEX;
close BINARY;
close BINARY2;

my $input_size = (-s 'INPUT_SAVE');
my $index_size = (-s 'INDEX');
my $binary_size = (-s 'BINARY');
my $binary2_size = (-s 'BINARY2');

`bzip2 -kf INPUT_SAVE`;
`bzip2 -kf INDEX`;
`bzip2 -kf BINARY`;
`bzip2 -kf BINARY2`;

my $input_bz2_size = (-s 'INPUT_SAVE.bz2');
my $index_bz2_size = (-s 'INDEX.bz2');
my $binary_bz2_size = (-s 'BINARY.bz2');
my $binary2_bz2_size = (-s 'BINARY2.bz2');
print "INPUT SIZE:\t$input_size\n";
print "INPUT Bz2:\t$input_bz2_size\n";
print "INDEX Bz2:\t$index_bz2_size\n";
print "BINARY Bz2:\t$binary_bz2_size\n";
print "BINARY2 Bz2:\t$binary2_bz2_size\n";
printf "Index  compressibility:\t%f\n", ($index_size/$index_bz2_size);
printf "Binary compressibility:\t%f\n", ($binary_size/$binary_bz2_size);
printf "Binary2 compressibility:\t%f\n", ($binary2_size/$binary2_bz2_size);
printf "Total Bz2 Output Size:\t%d\n", $binary_bz2_size+$index_bz2_size+$binary2_bz2_size;
printf "Savings ratio: %f\n", $input_bz2_size/($binary_bz2_size+$index_bz2_size+$binary2_bz2_size);

print "$rows_with_deletes rows have deletes\n";
print "$rows_with_copies rows have copies\n";
print "$rows_with_refs rows have refs\n";
print "$rows_with_lits rows have lits\n";
print "$rows_using_a_predictor use at least one predictor\n";


$Data::Dumper::Useqq=1;
#print Dumper \@fields_to_vals;

#print Dumper \@col_to_val_to_key_idx;
