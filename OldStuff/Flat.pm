# find better name?? File::Tabular ??
# check word 'splices'

package File::Flat;

use strict;
use warnings;
no warnings 'uninitialized';

use Carp;
use Fcntl ':flock';
use Carp::Assert;
use Hash::Type;

use Data::Dumper;

use constant BUFSIZE => 1 << 21; # 2MB, used in copyData


our $VERSION = "0.01"; 


=begin comment

-prepare => query


===========================================

Queries 

field:word                  => field =~ /^.*\bword\b
field:"a couple of words"   => field =~ /^.*\ba\s+couple\s+of\s+words\b
field:wor*                  => field =~ /^.*\bwor\w*\b  


field:~regex
field:(=|<|>|<=|>=|!=) num
field:(eq|ne|ge|gt|le|lt) string
field:op(=|<|>|<=|>=|!=) apply $cmp{op} from Query->new

 ex field:d>=01.01.2003    $cmp{d} = sub{}


}


=end comment



=head1 NAME

File::Flat - utilities for working with flat files

=head1 SYNOPSIS



=head1 DESCRIPTION



=cut



=head1 METHODS

=over

=item new (openparams, args)

=over

=item openparams

List of arguments for opening the file ; these will 
be fed directly to L<perlfunc|open>. Can also be a reference
to an already opened filehandle.

=item args 

a reference to a hash containing following keys :

=over

=item fieldSep

field separator ('|' by default) :
any character except '%'.

=item recordSep

record separator ('\n' by default)

=item fieldSepRepl

string to substitute if fieldSep is met in the data.
(by default, url encoding of B<fieldSep>, i.e. '%7C' )

=item recordSepRepl

string to substitute if recordSep is met in the data 
(by default, url encoding of B<recordSep>, i.e. '%0A' )


=item autoNumField

name of field for which autonumbering is turned on (none by default).
This is useful to generate keys : when 
you write a record, the character '#' in that field will be
replaced by a fresh number, incremented automatically.
Initial value of the counter 1 + the largest number read
I<so far> (it is your responsability to read all records
before the first write operation).

=item autoNumMax

initial value of the counter for autonumbering (1 by default).

=item autoNumChar

character that will be substituted by an autonumber when
writing records ('#' by default).


=item flockMode

mode for locking the file, see L<perlfunc|flock>. By default,
this will be LOCK_EX if B<openargs> contains 'E<gt>' or
'+E<lt>', LOCK_SH otherwise.

=item flockAttempts

Number of attempts to lock the file,
at 1 second intervals, before returning an error.
Zero by default.
If nonzero, LOCK_NB is added to flockMode;
if zero,  a single locking attempt will be made, blocking
until the lock is available.

=item headers

reference to an array of field names.
If not present, headers will be read from the first line of
the file.

=item printHeaders

if true, the B<headers> will be printed to the file.
If not specified, treated as 'true' if
B<openargs> contains 'E<gt>'.

=item journal

name of journaling file, or reference to a list of arguments
for L<perlfunc|open>. The journaling file will log all write operations.
If specified as a file name, will be  be opened in 'E<gt>E<gt>' mode.

=back



=back

=cut



use constant DEFAULT => {
  fieldSep      => '|',
  recordSep     => "\n",
  autoNumField  => undef, 			
  autoNumChar   => '#', 			
  autoNumMax    => 1, 			
  lockAttempts  => 0
};


sub new {
  my $class = shift;
  my $args = ref $_[-1] eq 'HASH' ? pop : {};

  # create object with default values
  my $self = bless {};
  $self->{$_} = $args->{$_} || DEFAULT->{$_} 
    foreach qw(fieldSep recordSep autoNumField autoNumChar autoNumMax);

  # field and record separators
  croak "can't use '%' as field separator" if $self->{fieldSep} eq '%';
  $self->{recordSepRepl} = $args->{recordSepRepl} || 
                           urlEncode($self->{recordSep});
  $self->{fieldSepRepl} = $args->{fieldSepRepl} || 
                           urlEncode($self->{fieldSep});
  $self->{rgx} = qr/\Q$self->{fieldSep}\E/;

  # open file and get lock
  _open($self->{FH}, @_) or croak "open @_ : $^E";
  my $flockAttempts =  $args->{flockAttempts} || 0;
  my $flockMode =  $args->{flockMode} ||
    $_[0] =~ />|\+</ ? LOCK_EX : LOCK_SH;
  $flockMode |= LOCK_NB if $flockAttempts > 0;
  for (my $n = $flockAttempts; $n >= 1; $n--) {
    last if flock $self->{FH}, $flockMode; # exit loop if flock succeeded
    $n > 1 ? sleep(1) : croak "could not flock @_: $^E";
  };

  # setup journaling
  if (exists $args->{journal}) { 
    my $j = {}; # create a fake object for _printRow
    $j->{$_} = $self->{$_} foreach qw(fieldSep recordSep 
				      fieldSepRepl recordSepRepl);
    _open($j->{FH}, ref $args->{journal} eq 'ARRAY' ? @{$args->{journal}}
	                                            : ">>$args->{journal}")
      or croak "open journal $args->{journal} : $^E";
    $self->{journal} = bless $j;
  }

  # field headers
  my $h = $args->{headers} || [split($self->{rgx}, $self->_getLine, -1)];
  $self->{ht} = new Hash::Type(@$h);
  $self->_printRow(@$h) if 
    exists $args->{printHeaders} ? $args->{printHeaders} : ($_[0] =~ />/);

  # ready for reading data lines
  $self->{dataStart} = tell($self->{FH});
  $. = 0;	# setting line counter to zero for first dataline
  return $self;
}



sub DESTROY {
  my $self = shift;
  close $self->{FH};
}


sub _open { # because of 'open' funny prototyping, need to decompose args
  return $_[0] = $_[1] if ref $_[1] eq 'GLOB'; # got a filehandle
  return open($_[0], $_[1], $_[2], @_[3..$#_]) if @_ > 3;
  return open($_[0], $_[1], $_[2])             if @_ > 2;
  return open($_[0], $_[1]);                   #otherwise
}


sub _getLine { 
  my $self = shift;
  local $/ = $self->{recordSep};
  my $line = readline $self->{FH};
  if (defined $line) {
    chomp $line;
    $line =~ s/$self->{recordSepRepl}/$self->{recordSep}/g;
  }
  return $line;
}


sub _printRow {
  my ($self, @vals) = @_;

  if ($self->{autoNumField}) { # autoNumbering
    my $ix = $self->{ht}{$self->{autoNumField}} - 1;
    if ($vals[$ix] =~ s/$self->{autoNumChar}/$self->{autoNumMax}/) {
      $self->{autoNumMax} += 1;
    } 
    elsif ($vals[$ix] =~ m/(\d+)/) {
      $self->{autoNumMax} = $1 + 1 if $1 + 1 > $self->{autoNumMax};
    } 
  }

  s/$self->{fieldSep}/$self->{fieldSepRepl}/g foreach @vals;
  my $line = join $self->{fieldSep}, @vals;
  $line =~ s/$self->{recordSep}/$self->{recordSepRepl}/g;
  my $fh = $self->{FH};
  print $fh $line, $self->{recordSep};
}


=item fetchrow(query)

returns the next record matching the (optional) query. 
If there is no query, just returns the next record.

=cut


sub fetchrow {
  my $self = shift;
  my $q = shift;
  while (my $line = $self->_getLine) {
    next if ref $q eq 'Regexp' and $line !~ $q;
    my @vals = split $self->{rgx}, $line, -1;
    s/$self->{fieldSepRepl}/$self->{fieldSep}/g foreach @vals;

    if ($self->{autoNumField}) {
      my $ix = $self->{ht}{$self->{autoNumField}} - 1;
      my ($n) = $vals[$ix] =~ m/(\d+)/;
      $self->{autoNumMax} = $n+1 if $n and $n+1 > $self->{autoNumMax};
    }

    my $record = $self->{ht}->new(@vals);
    return $record unless ref $q eq 'Query' and not $q->match($record);
  }
  return undef;
}

=item fetchall(query, @keys)

finds all next records matching the (optional) query.
Keys are also optional. Return value depends on 
context and on the B<@keys> argument :

=over

=item * 

if B<@keys> is empty, and we are in a scalar context, then
it returns a reference to an array of records
matching the query (or, if there is no query, of all remaining records).


=item * 

if B<@keys> is not empty, and we are in a scalar contect, then
it returns a reference to a hash. 
Keys of the hash are built by taking one or several values 
from the records, according to the list of field names in B<@keys>;
if this list has more than one name, then the values are concatenated
according to L<perlvar|$;>.
Obviously, values of the hash are references to those records.


=item * 

if we are in a list context, then
it returns a pair : first item is a reference to an array or a hash, 
depending on B<@keys> as described above;
second item is a reference to an array of line numbers
corresponding to those records (first dataline has number 0).

=back

=cut

sub fetchall { 
  my $self = shift;
  my $q = (ref $_[0] eq 'Regexp') ? shift : undef;

  my $rows = @_ ? {} : []; # will return hash or array ref, depending on @keys
  my $line_nos = [];

  while (my $row = $self->fetchrow($q)) {
    if (@_) { $rows->{join($;, @{$row}{@_})} = $row; } 
    else    { push @$rows, $row;   }
    push @$line_nos, $. - 1 if wantarray;
  }

  return wantarray ? ($rows, $line_nos) : $rows;
}



=item rewind

Rewinds the file to the first data line (after the headers)

=cut

sub rewind {
  my $self = shift;
  seek $self->{FH}, $self->{dataStart}, 0;
  $. = 0;
}


=item clear

removes all datalines (but keeps the header line)

=cut

sub clear {
  my $self = shift;
  $self->rewind;
  $self->_journal('CLEAR');
  truncate $self->{FH}, $self->{dataStart};
}


=item headers

returns the list of field names

=cut

sub headers {
  my $self = shift;
  $self->{ht}->names;
}


=item splices

  splices(pos1 => 2, undef,           # delete 2 lines
          pos2 => 1, row,             # replace 1 line
          pos3 => 0, [row1, row2 ...] # insert lines
              ...
          -1   => 0, [row1, ...     ] # append lines
           );

           # special case : autonum if pos== -1


rewrites the whole file, deleting, replacing or appending data lines.
Returns the number of "splice instructions" performed.
Splice instructions can also be passed as an array ref instead of a list.
Positions always refer to line numbers in the original file, before 
any modifications. Therefore, it makes no sens to write

  splices(10 => 5, undef,     
          12 => 0, $myRow)

because after deleting 5 rows at line 10, we cannot insert a new
row at line 12.

=cut



sub splices {
  my $self = shift;
  my $args = ref $_[0] eq 'ARRAY' ? $_[0] : \@_;

  croak "splices : number of arguments must be multiple of 3" if @$args % 3;

  my $TMP = undef;	# handle for a tempfile

  my $i;
  for ($i=0; $i < @$args; $i+=3 ) {
    my ($pos, $del, $lines) = @$args[$i, $i+1, $i+2];

    $self->_journal('SPLICE', $pos, $del, $lines);

    if ($pos == -1) { # we want to append new data at end of file
      $TMP ?  # if we have a tempfile ...
	     copyData($TMP, $self->{FH}) # copy back all remaining data
	   : seek $self->{FH}, 0, 2;     # otherwise goto end of file
      $pos = $.; # sync positions (because of test 12 lines below)
    }
    elsif (           # we want to put data in the middle of file and ..
           not $TMP and                  # there is no tempfile yet and ..
	    (stat $self->{FH})[7] >      # size of file is bigger ..
	          $self->{dataStart}) {  # than first dataline

      open $TMP, "+>", undef or croak "no tempfile: $^E";

      $self->rewind;
      copyData($self->{FH}, $TMP);
      $self->rewind; 
      seek $TMP, 0, 0;
    }

    croak "splices : cannot go back to line $pos" if $. > $pos;

    local $/ = $self->{recordSep};

    while ($. < $pos) { # sync with tempfile
      my $line = <$TMP>;
      croak "splices : no such line : $pos ($.)" unless defined $line;
      my $fh = $self->{FH};
      print $fh $line;
    }

    while ($del--) {  # skip lines to delete from tempfile
      my $line = <$TMP>;
      croak "splices : no line to delete at pos $pos" unless defined $line;
    }

    $lines = [$lines] if ref $lines eq 'HASH'; # single line
    $self->_printRow(@{$_}{$self->headers}) for @$lines;
  }
  copyData($TMP, $self->{FH}) if $TMP; # copy back all remaining data
  truncate $self->{FH}, tell $self->{FH};
  $self->_journal('ENDSPLICES');
  return $i / 3;
}



=item append($row1, $row2, ...)


a shorthand for 

  splices([-1 => 0, [$row1, $row2, ...]])

=cut


sub append {
  my $self = shift;
  my $args = ref $_[0] eq 'ARRAY' ? $_[0] : \@_;
  $self->splices([-1 => 0, $args]);
}


sub copyData {
  my ($f1, $f2) = @_;
  local $/ = \BUFSIZE;
  while (my $buf = readline $f1) {print $f2 $buf;}
}

sub writeKeys {
  my $self = shift;
  my $modifs = shift;

  my $clone = bless {%$self};
  $clone->{FH} = undef;  
  open $clone->{FH}, "+>", undef or croak "no tempfile: $^E";

  seek $self->{FH}, 0, 0; # rewind to start of FILE (not start of DATA)
  copyData($self->{FH}, $clone->{FH});
  $self->rewind;
  $clone->rewind;

  $self->_journal('KEY', $_, $modifs->{$_}) foreach keys %$modifs;
  $self->_journal('ENDKEYS');

  while (my $row = $clone->fetchrow) {
    my $k = @{$row}{@_};
    my $data = exists $modifs->{$k} ? $modifs->{$k} : $row;
    $self->_printRow(@{$data}{$self->headers}) if $data;
    delete $modifs->{$k};
  }

  # add remaining values (new keys)
  $self->_printRow(@{$_}{$self->headers}) foreach grep {$_} values %$modifs;  

  truncate $self->{FH}, tell $self->{FH};
}


sub urlEncode {
  my $s = shift;
  return join "", map {sprintf "%%%02X", ord($_)} split //, $s;
}



sub _journal {
  my $self = shift;
  return if not $self->{journal}; # return if no active journaling 

  my @t = localtime;
  $t[5] += 1900;
  $t[4] += 1;
  my $t = sprintf "%04d-%02d-%02d %02d:%02d:%02d", @t[5,4,3,2,1,0];

  my @args = @_;
  my $rows = [];
  for (ref $args[-1]) { # last arg is an array of rows or a single row or none
    /ARRAY/ and do {($rows, $args[-1]) = ($args[-1], scalar(@{$args[-1]}))};
    /HASH/  and do {($rows, $args[-1]) = ([$args[-1]], 1)};
  }

  $self->{journal}->_printRow($t, 'ROW', @{$_}{$self->headers}) foreach @$rows;
  $self->{journal}->_printRow($t, @args);
}



sub playJournal {
  my $self = shift;
  croak "cannot playJournal while journaling is on!" if $self->{journal};
  my $J;
  _open($J, @_) or croak "open @_: $^E";

  my @rows = ();
  my @splices = ();
  my @writeKeys = ();

  local $/ = $self->{recordSep};

  while (my $line = <$J>) {
    chomp $line;

    $line =~ s/$self->{recordSepRepl}/$self->{recordSep}/g;
    my ($t, $ins, @vals) = split $self->{rgx}, $line, -1;
    s/$self->{fieldSepRepl}/$self->{fieldSep}/g foreach @vals;

    for ($ins) {
      /^CLEAR/   and do {$self->clear; next };
      /^ROW/     and do {push @rows, $self->{ht}->new(@vals); next};
      /^SPLICE/  and do {my $nRows = pop @vals;
			carp "invalid number of data rows in journal at $line"
			  if ($nRows||0) != @rows;
		        push @splices, @vals, $nRows ? [@rows] : undef;
		        @rows = ();
		        next };
      /^ENDSPLICES/ and do {$self->splices(@splices); @splices = (); next};
      /^KEY/     and do {my $nRows = pop @vals;
			carp "invalid number of data rows in journal at $line"
			  if ($nRows||0) > 1;
			push @writeKeys, $vals[0], $nRows ? $rows[0] : undef;
		        @rows = ();
		        next };
      /^ENDKEYS/ and do {$self->writeKeys({@writeKeys}); @writeKeys = (); next};
    }
  }
}




=begin comment

    # extraction des mots de la requ�te (obligatoires, � exclure, autres mots)
    my ($pluswords, $minuswords, $simplewords) = analyse_request($search_string);

    # cha�nes � ins�rer avant et apr�s les mots reconnus 
    my $pre_match = $tdb_param{_pre_match} || "";   # p. ex. "<font color=red>"
    my $post_match = $tdb_param{_post_match} || ""; # p. ex. "</font>"

    if ($search_string =~ /^\+?"?\*"?/) { # si la requ�te n'est qu'une �toile
	$pre_match = $post_match = "";    # alors pas d'insertion de pr�/post
    }

    my $count_lines = 0;	# nombre de lignes retenues

    # fonction qui d�cide si une ligne est � retenir ou non.
    # si oui, la fonction ins�re �galement les cha�nes pr�/post
    my $matchLine = sub {
	return 0 if $count_lines >= $max_records; 

 	foreach my $word (@$pluswords) { # pour chaque mot obligatoire
	    return 0 if not s/$word/$1$pre_match$2$post_match/g;
	}
  	foreach my $word (@$minuswords) { # pour chaque mot � exclure
	    return 0 if /$word/;
	}
	my $r = 0;
	if (@$pluswords) {$r = 1;} # s'il y a au moins un mot obligatoire,
				   # tous les autres n'ont plus d'importance
	else {		# sinon, on cherche au moins l'un des mots "simples"
	    foreach my $word (@$simplewords) {
		$r = 1 if s/$word/$1$pre_match$2$post_match/g;
	    }
	}
	$count_lines += 1 if $r;
	return $r;
    };

    my @records = map {build_record($_)} grep {&$matchLine($_)} <D>;
    close D;

    my $sort_crit = $tdb_param{_sort_by} || $cgi->param('SB') || undef;

    display_lines(\@records, 
		  $sort_crit,
		  "$full_url?SC=$SC&S=$search_string", 
		  search_string => $search_string,
		  search_type => "dans les m�tadonn�es", 
		  doc => $cgi->param('doc') || undef);
}







sub mkRegex {
    my $request = shift;
    my $fields = shift;

    my @pluswords = ();		# words with '+' : compulsory
    my @minuswords = ();	# words with '-' : to exclude
    my @simplewords = ();	# no indication : at least one of these
                                # must be present, if not @pluswords
    
    $request =~  s/^\s+//;	# suppression des espaces initiaux

     while ($request) {   
	my $flag = "";		# signe +/- (optionnel)
	my $field = "";		# nom de champ (optionnel)
	my $str = "";		# texte � reconna�tre
	if ($request =~  s/^(\+|\-)\s*//) {$flag = $1;}
	if ($request =~  s/^([\w]*)\s*:\s*//) {$field = $1;}
	if ($request =~  s/^\"([^\"]*)\"\s*//) {
	    $str = $1;
	    $str =~ s/\s+/\\s+/g; # remplacement des espaces par le motif \s+
	}
	elsif ($request =~  s/^([^\s]+)\s*//) {$str = $1;}
	else {&error("Requ�te vide: invalide");}

	$str =~ s/\*/\\w*/g;	# remplacement de l'�toile (regex simplifi�e)
	                        #   par la v�ritable regex


	# limites de mots requises seulement s'il s'agit d'un mot
	my $wdini = ($str =~ /^\w/) ? '\b' : '';
	my $wdfin = ($str =~ /\w$/) ? '\b' : '';

	eval { $str = qr/$wdini$str$wdfin/i; }
        or do { my $msg = $@;
	        $msg =~ s[^.*?HERE in m/][];
	        $msg =~ s[/ at .*][];
	        $msg =~ s[HERE][A CET ENDROIT];
	        error("recherche incorrecte : $msg"); };

	# remplacement des caract�res accentu�s par des classes
	$str =~ s/�/[�c]/g;
	$str =~ s/([����])/[a$1]/g;
	$str =~ s/([����])/[e$1]/g;
	$str =~ s/([����])/[i$1]/g;
	$str =~ s/([����])/[o$1]/g;
	$str =~ s/([����])/[u$1]/g;
	$str =~ s/([��])/[y$1]/g;



	if ($field) {	# au cas o� le nom de champ est donn�
	    my $fn = 0;
	    my $match_field = qr/^\Q$field\E$/i;
	    foreach (@fields) {
		last if /$match_field/;
		$fn += 1;
	    }
	    &error("nom de champ invalide: $field") if ($fn > @fields);
	    # construction de l'expression r�guli�re
	    $str = qr/^		# d�but de ligne
		      (         # capture dans $1
		      (?:[^$FS]*\Q$FS\E){$fn} # saute $fn champs
	              [^$FS]*	# saute d�but du champ
		      )		# fin $1
		      ($str)  # mot sp�cifi� dans $str, capture dans $2
		     /xi;
	}

	else {	# au cas o� l'on cherche sur n'importe quel champ
	    $str = qr/()($str)/i; # capture dans $2
	}

	if ($flag eq '+' or ($flag eq '' and $SC eq 'ALL')) {
	    push @pluswords, $str;
	}
	elsif ($flag eq '-') {
	    push @minuswords, $str;
	}
	else {
	    push @simplewords, "(?:$str)";
	} # parenth�ses non-capturantes
    }

    return \@pluswords, \@minuswords, \@simplewords;
}




=end comment

1;
