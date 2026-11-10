#!/usr/bin/perl
# Ken French factor analysis: does value (HML) lose in bull runs and win in bear markets?
# usage: perl tools/ff_analysis.pl <factors.csv> [start_yyyymm]
use strict; use warnings;
my ($file, $start) = ($ARGV[0], $ARGV[1] // 0);
open my $h, '<', $file or die $!; my @m;
while (<$h>) { last if /Annual Factors/; next unless /^\s*(\d{6})\s*,\s*(-?[\d.]+)\s*,\s*(-?[\d.]+)\s*,\s*(-?[\d.]+)\s*,\s*(-?[\d.]+)/; next if $1 < $start; next if $4 <= -99; push @m, { d => $1, mkt => $2 + $5, hml => $4 }; }
printf "%s: %d months %s to %s\n", $file, scalar(@m), $m[0]{d}, $m[-1]{d};
sub stats { my @x = @_; return (0, 0, 0) unless @x; my $s = 0; $s += $_ for @x; my $w = grep { $_ > 0 } @x; return ($s / @x * 12, 100 * $w / @x, scalar @x) }
# index, trailing 12m, drawdown
my ($ix, $pk) = (1, 1);
for my $i (0 .. $#m) { $ix *= 1 + $m[$i]{mkt} / 100; $pk = $ix if $ix > $pk; $m[$i]{ix} = $ix; $m[$i]{dd} = $ix / $pk - 1;
  if ($i >= 12) { $m[$i]{t12} = $ix / $m[$i - 12]{ix} - 1 } }
print "\nA. Same month: market up vs down\n";
for my $r (['Market up month', sub { $_[0]{mkt} > 0 }], ['Market down month', sub { $_[0]{mkt} <= 0 }], ['Market down more than 5%', sub { $_[0]{mkt} < -5 }], ['Market up more than 5%', sub { $_[0]{mkt} > 5 }]) {
  my $f = $r->[1]; printf "  %-28s HML %+6.1f%% pa, positive %2.0f%% of %d months\n", $r->[0], stats(map { $_->{hml} } grep { $f->($_) } @m); }
print "\nB. By trailing 12-month market return (regime at start of month -> HML that month)\n";
for my $b ([-9, -0.10, 'below -10%'], [-0.10, 0, '-10% to 0%'], [0, 0.10, '0% to +10%'], [0.10, 0.20, '+10% to +20%'], [0.20, 0.30, '+20% to +30%'], [0.30, 9, 'above +30%']) {
  my @x = map { $m[$_]{hml} } grep { defined $m[$_ - 1]{t12} && $m[$_ - 1]{t12} >= $b->[0] && $m[$_ - 1]{t12} < $b->[1] } 13 .. $#m;
  printf "  %-16s HML %+6.1f%% pa, positive %2.0f%% of %d months\n", $b->[2], stats(@x); }
print "\nC. By drawdown state (start of month)\n";
for my $b ([-0.05, 1, 'within 5% of high'], [-0.20, -0.05, '5% to 20% below'], [-9, -0.20, 'more than 20% below']) {
  my @x = map { $m[$_]{hml} } grep { $m[$_ - 1]{dd} >= $b->[0] && $m[$_ - 1]{dd} < $b->[1] } 1 .. $#m;
  printf "  %-22s HML %+6.1f%% pa, positive %2.0f%% of %d months\n", $b->[2], stats(@x); }
# correlation
my $n = @m; my ($sx, $sy, $sxx, $syy, $sxy) = (0) x 5; for (@m) { $sx += $_->{mkt}; $sy += $_->{hml}; $sxx += $_->{mkt}**2; $syy += $_->{hml}**2; $sxy += $_->{mkt} * $_->{hml} }
printf "\nD. Monthly correlation HML vs market: %.2f\n", ($n * $sxy - $sx * $sy) / sqrt(($n * $sxx - $sx**2) * ($n * $syy - $sy**2));
print "\nE. Bear markets (peak to trough, 20%+ fall in monthly total-return index) and the 12 months before the peak\n";
my ($pi, $ti, $inb) = (0, 0, 0); my @ep;
for my $i (1 .. $#m) { if ($m[$i]{ix} >= $m[$pi]{ix}) { push @ep, [$pi, $ti] if $inb; $inb = 0; $pi = $i; $ti = $i; next } if ($m[$i]{ix} < $m[$ti]{ix}) { $ti = $i; $inb = 1 if $m[$ti]{ix} / $m[$pi]{ix} - 1 <= -0.20 } }
push @ep, [$pi, $ti] if $inb;
my ($bw, $rw) = (0, 0);
for my $e (@ep) { my ($p, $t) = @$e; my ($c, $r) = (1, 1); $c *= 1 + $m[$_]{hml} / 100 for $p + 1 .. $t; my $s = $p - 11 < 0 ? 0 : $p - 11; $r *= 1 + $m[$_]{hml} / 100 for $s .. $p; my $mr = $m[$p]{ix} / $m[$s > 0 ? $s - 1 : 0]{ix} - 1;
  $bw++ if $c > 1; $rw++ if $r < 1;
  printf "  %s to %s  market %+5.0f%%  HML in the bear %+6.1f%%  | 12m run-up: market %+5.0f%%, HML %+6.1f%%\n", $m[$p]{d}, $m[$t]{d}, 100 * ($m[$t]{ix} / $m[$p]{ix} - 1), 100 * ($c - 1), 100 * $mr, 100 * ($r - 1); }
printf "  value won in %d of %d bear markets; value lost in the run-up to %d of %d peaks\n", $bw, scalar(@ep), $rw, scalar(@ep);
