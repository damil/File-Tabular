use strict;
use warnings;
no warnings 'uninitialized';

use Test::More tests => 25 ;


BEGIN {use_ok("File::Tabular");}


my $f = new File::Tabular("t/htmlEntities.txt");


printf "size = %d\n",  $f->stat->{size};
printf "mtime = %s\n",  scalar(localtime($f->stat->{mtime}));

printf "h:m:d = %d:%d:%d\n",  $f->mtime->{hour}, $f->mtime->{min}, $f->mtime->{sec}; 

