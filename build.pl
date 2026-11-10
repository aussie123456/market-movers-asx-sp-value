#!/usr/bin/perl
# Value vs Research Desk - builder. Runs the same locally (Git Bash perl) and in GitHub Actions.
#   perl build.pl [--limit N] [--previous previous.json] [--out dist]
# 1. Universe: S&P 500 (datasets CSV) + S&P/ASX 200 (Wikipedia wikitext); falls back to data/universe.json.
# 2. Yahoo v7 quote (batched) + quoteSummary per stock (consensus, targets, broker rating changes).
# 3. Value score = sector-relative percentile blend. Research view = consensus rating + target upside.
# 4. Google News broker headlines for the top value names; X posts only if X_BEARER_TOKEN is set.
# Public data only. Not investment advice.
use strict; use warnings; use JSON::PP; use File::Path qw(make_path); use POSIX qw(strftime floor);
use Time::HiRes qw(sleep);

my %o = (limit => 0, previous => '', out => 'dist');
while (@ARGV) { my $a = shift; if ($a =~ /^--(limit|previous|out)$/) { $o{$1} = shift } }
my $UA  = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0 Safari/537.36';
my $JAR = "/tmp/vr-yahoo-cookies.txt";
my $J   = JSON::PP->new->canonical(1);
my $NOW = time; my @log;
sub note { my $m = shift; print "$m\n"; push @log, $m; }

sub curl { my ($url, @extra) = @_; my $q = join ' ', map { "'$_'" } @extra; my $b = `curl -sS -L --max-time 40 -A '$UA' $q '$url' 2>/dev/null`; return $b // ''; }
sub js   { my $b = shift; my $r = eval { JSON::PP->new->utf8(1)->decode($b) }; return $r; }
sub esc  { my $s = shift; $s =~ s/([^A-Za-z0-9\-_.~])/sprintf('%%%02X', ord($1))/ge; $s }
sub slurp { my $f = shift; open my $h, '<:raw', $f or return ''; local $/; my $t = <$h>; close $h; $t }
sub num  { my $v = shift; return undef unless defined $v; $v = $v->{raw} if ref $v eq 'HASH'; return undef unless defined $v && !ref $v && $v =~ /^-?[\d.]+(?:[eE][-+]?\d+)?$/; return $v + 0 }
sub r2   { my ($v, $d) = @_; return undef unless defined $v; return sprintf("%.${d}f", $v) + 0 }

# ---------- 1. universe ----------
my @uni;
{
  my $csv = curl('https://raw.githubusercontent.com/datasets/s-and-p-500-companies/main/data/constituents.csv');
  my @rows = split /\r?\n/, $csv; shift @rows;
  for (@rows) {
    my @f; while (/\G(?:"((?:[^"]|"")*)"|([^,]*))(?:,|$)/g) { push @f, defined $1 ? $1 : $2; last if pos == length }
    next unless $f[0] && $f[0] =~ /^[A-Z.]+$/;
    (my $y = $f[0]) =~ s/\./-/;
    push @uni, { m => 'SPX', code => $f[0], y => $y, name => $f[1], sector => $f[2] };
  }
  my $sp = grep { $_->{m} eq 'SPX' } @uni;
  my $wt = curl('https://en.wikipedia.org/w/index.php?title=S%26P/ASX_200&action=raw');
  utf8::decode($wt);
  if ($wt =~ /\{\|\s*class="wikitable sortable"\s*\n!\s*Code(.*?)\n\|\}/s) {
    for my $row (split /\n\|-/, $1) {
      my @c = grep { length } map { s/^\|\s*//; $_ } grep { /^\|/ } split /\n/, $row;
      next unless @c >= 3 && $c[0] =~ /^([A-Z0-9]{3,4})\b/;
      my $code = $1; my $nm = $c[1]; $nm =~ s/\[\[(?:[^\]|]*\|)?([^\]]*)\]\]/$1/g; $nm =~ s/<[^>]*>|\{\{[^}]*\}\}//g; $nm =~ s/^\s+|\s+$//g;
      my $sec = $c[2]; $sec =~ s/\[\[(?:[^\]|]*\|)?([^\]]*)\]\]/$1/g; $sec =~ s/^\s+|\s+$//g;
      $sec = 'Health Care' if $sec =~ /^Health/i; $sec = 'Communication Services' if $sec =~ /^(Tele|Commun)/i;
      push @uni, { m => 'ASX', code => $code, y => "$code.AX", name => $nm, sector => $sec };
    }
  }
  my $ax = grep { $_->{m} eq 'ASX' } @uni;
  note("universe: S&P 500 $sp, ASX 200 $ax");
  if ($sp < 400 || $ax < 150) {
    my $fb = js(slurp('data/universe.json'));
    if ($fb) { my %have = map { $_->{m} => 1 } ($sp >= 400 ? grep { $_->{m} eq 'SPX' } @uni : ()), ($ax >= 150 ? grep { $_->{m} eq 'ASX' } @uni : ());
      @uni = ((grep { $have{$_->{m}} } @uni), (grep { !$have{$_->{m}} } @$fb)); note("universe fallback used: now ".scalar(@uni)); }
  } else { make_path('data'); open my $h, '>:raw', 'data/universe.json'; print $h JSON::PP->new->utf8(1)->canonical(1)->encode(\@uni); close $h; }
}
if ($o{limit}) { my %n; @uni = grep { ++$n{$_->{m}} <= $o{limit} } @uni; }
die "no universe\n" unless @uni;

# ---------- 2. Yahoo ----------
my $crumb = '';
sub get_crumb { for my $t (1..4) { curl('https://fc.yahoo.com', '-c', $JAR, '-o', '/dev/null'); $crumb = curl('https://query2.finance.yahoo.com/v1/test/getcrumb', '-b', $JAR, '-c', $JAR); $crumb =~ s/\s+//g;
  return 1 if length($crumb) && length($crumb) < 30 && $crumb !~ /[{<]/; $crumb = ''; sleep(3 + 4 * $t); } return 0 }
unlink $JAR; note("yahoo crumb: ".(get_crumb() ? 'ok' : 'FAILED'));

my %prev; if ($o{previous} && -s $o{previous}) { my $p = js(slurp($o{previous})); if ($p && $p->{stocks}) { $prev{$_->{y}} = $_ for @{$p->{stocks}}; note("previous data: ".scalar(keys %prev)." stocks available for back-fill"); } }

my (%q, %fx);
if ($crumb) {
  my @y = map { $_->{y} } @uni;
  while (my @b = splice(@y, 0, 80)) {
    for my $try (0..2) { my $r = js(curl('https://query1.finance.yahoo.com/v7/finance/quote?symbols='.join(',', @b).'&crumb='.esc($crumb), '-b', $JAR));
      if ($r && $r->{quoteResponse}{result}) { $q{$_->{symbol}} = $_ for @{$r->{quoteResponse}{result}}; last } sleep(3 + 5 * $try); get_crumb() if $try == 1; }
  }
  note("quotes: ".scalar(keys %q)." of ".scalar(@uni));
  my %pairs; for (values %q) { my ($f, $c) = ($_->{financialCurrency}, $_->{currency}); $pairs{$f eq "USD" ? "$c=X" : "$f$c=X"} = 1 if $f && $c && $f ne $c; }
  if (%pairs) { my $r = js(curl('https://query1.finance.yahoo.com/v7/finance/quote?symbols='.join(',', keys %pairs).'&crumb='.esc($crumb), '-b', $JAR));
    if ($r) { $fx{$_->{symbol}} = $_->{regularMarketPrice} for @{$r->{quoteResponse}{result} // []} } note("fx pairs: ".join(' ', map { "$_=".($fx{$_} // '?') } sort keys %pairs)); }
}

my ($qs_ok, $qs_fail, $streak) = (0, 0, 0); my %qs;
for my $u (@uni) {
  last unless $crumb; my $y = $u->{y}; next unless $q{$y};
  my $got;
  for my $try (0..2) {
    my $b = curl("https://query2.finance.yahoo.com/v10/finance/quoteSummary/$y?modules=financialData,defaultKeyStatistics,upgradeDowngradeHistory,recommendationTrend&crumb=".esc($crumb), '-b', $JAR);
    my $r = js($b);
    if ($r && $r->{quoteSummary}{result}) { $got = $r->{quoteSummary}{result}[0]; last }
    last if $r && $r->{quoteSummary}{error} && ($r->{quoteSummary}{error}{code} // '') eq 'Not Found';
    sleep(4 + 8 * $try); get_crumb() if $b =~ /crumb|Unauthorized/i;
  }
  if ($got) { $qs{$y} = $got; $qs_ok++; $streak = 0 } else { $qs_fail++; $streak++; if ($streak == 8) { note("quoteSummary: 8 failures in a row, pausing 60s"); sleep 60; get_crumb(); } last if $streak >= 20; }
  sleep 0.12; print "  quoteSummary $qs_ok ok / $qs_fail fail\n" if ($qs_ok + $qs_fail) % 100 == 0;
}
note("quoteSummary: $qs_ok ok, $qs_fail failed");

# ---------- 3. assemble + score ----------
my @S; my $stale = 0; my $SHORT_DATE = '';
for my $u (@uni) {
  my $y = $u->{y}; my $v = $q{$y}; my $d = $qs{$y};
  if (!$v || !$d) { if ($prev{$y}) { my %c = %{$prev{$y}}; $c{stale} = JSON::PP::true; push @S, \%c; $stale++; } next unless $v; next if $prev{$y}; }
  my $px = num($v->{regularMarketPrice}) or next; my $mc = num($v->{marketCap});
  my ($f, $k) = ($d->{financialData} // {}, $d->{defaultKeyStatistics} // {});
  my $conv = 1; my ($fc, $cc) = ($v->{financialCurrency}, $v->{currency}); if ($fc && $cc && $fc ne $cc) { $conv = $fx{$fc eq "USD" ? "$cc=X" : "$fc$cc=X"} }
  my $fpe = num($v->{forwardPE}); my $tpe = num($v->{trailingPE});
  my $fcf = num($f->{freeCashflow});
  my %s = (%$u, name => $u->{name} || $v->{longName} || $v->{shortName}, cur => $cc, px => r2($px, 2), mcap => $mc,
    chg => r2(num($v->{regularMarketChangePercent}), 2), y1 => r2(num($v->{fiftyTwoWeekChangePercent}), 1),
    hi => num($v->{fiftyTwoWeekHigh}), lo => num($v->{fiftyTwoWeekLow}),
    d200 => r2((num($v->{twoHundredDayAverageChangePercent}) // 0) * 100, 1),
    fpe => r2($fpe, 1), tpe => r2($tpe, 1), pb => r2(num($v->{priceToBook}), 2), dy => r2(num($v->{dividendYield}), 2),
    eveb => r2(num($k->{enterpriseToEbitda}), 1),
    fcfy => (defined $fcf && $mc && $conv ? r2($fcf * $conv / $mc * 100, 1) : undef),
    roe => (defined num($f->{returnOnEquity}) ? r2(num($f->{returnOnEquity}) * 100, 1) : undef),
    de => r2(num($f->{debtToEquity}), 0), eg => (defined num($f->{earningsGrowth}) ? r2(num($f->{earningsGrowth}) * 100, 0) : undef),
    epsf => num($v->{epsForward}), epst => num($v->{epsTrailingTwelveMonths}),
    rec => r2(num($f->{recommendationMean}), 2), nan => num($f->{numberOfAnalystOpinions}),
    tmean => r2(num($f->{targetMeanPrice}), 2), thi => r2(num($f->{targetHighPrice}), 2), tlo => r2(num($f->{targetLowPrice}), 2));
  if ($u->{m} eq 'SPX') { my ($sp, $ss, $pm) = (num($k->{shortPercentOfFloat}), num($k->{sharesShort}), num($k->{sharesShortPriorMonth})); if (defined $sp) { $s{sh} = r2($sp * 100, 1); $s{shc} = r2($sp * 100 * (1 - $pm / $ss), 1) if $ss && defined $pm; } }
  $s{up} = r2(($s{tmean} / $px - 1) * 100, 1) if $s{tmean};
  if (my $t = $d->{recommendationTrend}{trend}) { my ($t0) = grep { ($_->{period} // '') eq '0m' } @$t; $s{dist} = [map { $t0->{$_} // 0 } qw(strongBuy buy hold sell strongSell)] if $t0; }
  my @h = grep { ($_->{epochGradeDate} // 0) > $NOW - 120 * 86400 } @{$d->{upgradeDowngradeHistory}{history} // []};
  @h = sort { $b->{epochGradeDate} <=> $a->{epochGradeDate} } @h;
  my ($upg, $dng) = (0, 0); for (@h) { $upg++ if ($_->{action} // '') eq 'up'; $dng++ if ($_->{action} // '') eq 'down'; }
  $s{upg} = $upg; $s{dng} = $dng;
  $s{acts} = [map { { d => strftime('%Y-%m-%d', gmtime $_->{epochGradeDate}), firm => $_->{firm}, a => $_->{action}, from => $_->{fromGrade}, to => $_->{toGrade}, pt => num($_->{currentPriceTarget}) || undef, ppt => num($_->{priorPriceTarget}) || undef } } @h[0 .. ($#h < 7 ? $#h : 7)]];
  push @S, \%s;
}
note("stocks assembled: ".scalar(@S)." ($stale carried over from the previous run)");
die "no stock data at all - refusing to publish an empty page\n" unless @S;

# ASX short interest: ASIC daily aggregated short positions (published about four trading days in arrears).
{
  my $ix = js(curl('https://download.asic.gov.au/short-selling/short-selling-data.json'));
  my $rd = sub { my $e = shift or return {}; my $c = curl("https://download.asic.gov.au/short-selling/RR$e->{date}-$e->{version}-SSDailyAggShortPos.csv"); my %r;
    for (split /\r?\n/, $c) { $r{$2} = $3 + 0 if /^(.*),([A-Z0-9]{2,6}),\d+,\d+,\s*([\d.]+)\s*$/ } \%r };
  if ($ix && ref $ix eq 'ARRAY' && @$ix) {
    my ($now, $then) = ($rd->($ix->[0]), $rd->($ix->[20])); my $n = 0;
    for my $s (grep { $_->{m} eq 'ASX' && !$_->{stale} } @S) { next unless defined $now->{$s->{code}}; $s->{sh} = r2($now->{$s->{code}}, 1); $s->{shc} = r2($now->{$s->{code}} - $then->{$s->{code}}, 1) if defined $then->{$s->{code}}; $n++; }
    $SHORT_DATE = "$ix->[0]{date}"; $SHORT_DATE =~ s/(\d{4})(\d\d)(\d\d)/$1-$2-$3/;
    note("ASIC short positions: $n ASX stocks matched, report date $SHORT_DATE");
  } else { note("ASIC short positions: index not readable, skipped"); }
}

# percentile helpers: higher = cheaper. Sector-relative when the sector has >= 8 names with the metric, else market-relative.
my @MET = ( ['ey', 30, sub { my $s = shift; defined $s->{fpe} && $s->{fpe} > 0 ? 1 / $s->{fpe} : (defined $s->{epsf} && $s->{epsf} < 0 ? -1 : undef) }],
            ['ev', 25, sub { my $s = shift; defined $s->{eveb} && $s->{eveb} > 0 ? 1 / $s->{eveb} : undef }],
            ['fc', 20, sub { $_[0]{fcfy} }],
            ['bk', 15, sub { my $s = shift; defined $s->{pb} && $s->{pb} > 0 ? 1 / $s->{pb} : undef }],
            ['dv', 10, sub { $_[0]{dy} // 0 }] );
sub pct { my ($x, $arr) = @_; my $n = @$arr; return undef if $n < 2; my $lt = grep { $_ < $x } @$arr; my $eq = grep { $_ == $x } @$arr; return 100 * ($lt + 0.5 * ($eq - 1)) / ($n - 1 || 1) }
for my $m (qw(SPX ASX)) {
  my @ms = grep { $_->{m} eq $m && !$_->{stale} } @S;
  for my $met (@MET) { my ($key, $w, $fn) = @$met;
    my (%bysec, @all); for (@ms) { my $x = $fn->($_); next unless defined $x; push @all, $x; push @{$bysec{$_->{sector}}}, $x; }
    for (@ms) { my $x = $fn->($_); next unless defined $x; my $pool = @{$bysec{$_->{sector}} // []} >= 8 ? $bysec{$_->{sector}} : \@all; my $p = pct($x, $pool); $_->{p}{$key} = r2($p, 0) if defined $p; }
  }
  for my $s (@ms) {
    my ($sw, $sx, $n) = (0, 0, 0); for my $met (@MET) { my $p = $s->{p}{$met->[0]}; next unless defined $p; next if $met->[0] eq 'dv' && !$s->{dy}; $sw += $met->[1]; $sx += $met->[1] * $p; $n++; }
    $s->{val} = $n >= 3 ? r2($sx / $sw, 0) : undef;
    # value-trap flags
    my @fl; push @fl, 'Forward EPS below trailing' if defined $s->{epsf} && defined $s->{epst} && $s->{epst} > 0 && $s->{epsf} < $s->{epst} * 0.95;
    push @fl, 'ROE under 5%' if defined $s->{roe} && $s->{roe} < 5;
    push @fl, 'Debt/equity over 200%' if defined $s->{de} && $s->{de} > 200 && $s->{sector} !~ /Financ|Real Estate/;
    push @fl, 'More than 15% below 200-day average' if defined $s->{d200} && $s->{d200} < -15;
    push @fl, sprintf('Short interest %.1f%%', $s->{sh}) if defined $s->{sh} && $s->{sh} >= ($s->{m} eq 'ASX' ? 5 : 8);
    push @fl, 'Net broker downgrades (120d)' if $s->{dng} > $s->{upg};
    $s->{flags} = \@fl;
    # Street view
    my $st = 'none';
    if (defined $s->{rec} && ($s->{nan} // 0) >= 3 && defined $s->{up}) { $st = ($s->{rec} <= 2.2 && $s->{up} >= 10) ? 'bull' : ($s->{rec} >= 2.8 || $s->{up} <= 0) ? 'bear' : 'neutral'; }
    $s->{street} = $st;
    my $v = $s->{val};
    $s->{verdict} = !defined $v ? 'na' : $v >= 70 ? ($st eq 'bull' ? 'agree' : $st eq 'bear' ? 'disagree' : $st eq 'neutral' ? 'quiet' : 'uncovered') : ($v <= 30 && $st eq 'bull') ? 'crowded' : 'other';
  }
}

# ---------- 4. published research headlines (Google News) and optional X posts ----------
my (%news_for, $news_ok, $x_ok) = ((), 0, 0);
my @focus; for my $m (qw(SPX ASX)) { my @c = sort { $b->{val} <=> $a->{val} } grep { $_->{m} eq $m && !$_->{stale} && defined $_->{val} && $_->{val} >= 70 } @S; push @focus, @c[0 .. ($#c < 24 ? $#c : 24)]; }
for my $s (@focus) {
  (my $nm = $s->{name}) =~ s/\s+(Inc\.?|Corp\.?|Corporation|Limited|Ltd\.?|Group|Company|plc|Holdings?|\(.*?\))\s*$//i;
  my $qy = $s->{m} eq 'ASX' ? qq{"$nm" (ASX OR shares) (broker OR "price target" OR upgrade OR downgrade OR rating) when:30d} : qq{"$nm" $s->{code} ("price target" OR upgrade OR downgrade OR initiates OR analyst) when:30d};
  my $loc = $s->{m} eq 'ASX' ? 'hl=en-AU&gl=AU&ceid=AU:en' : 'hl=en-US&gl=US&ceid=US:en';
  my $x = curl('https://news.google.com/rss/search?q='.esc($qy)."&$loc"); utf8::decode($x);
  my @it; while ($x =~ m{<item>(.*?)</item>}gs) { my $i = $1; my ($t) = $i =~ m{<title>(.*?)</title>}s; my ($l) = $i =~ m{<link>(.*?)</link>}s; my ($p) = $i =~ m{<pubDate>(.*?)</pubDate>}s; my ($src) = $i =~ m{<source[^>]*>(.*?)</source>}s;
    next unless $t && $l; for ($t, $src) { next unless defined; s/&amp;/&/g; s/&quot;/"/g; s/&#39;/'/g; s/&lt;/</g; s/&gt;/>/g; } $t =~ s/\s+-\s+\Q$src\E$// if $src; push @it, { t => $t, u => $l, d => $p, s => $src }; last if @it >= 5; }
  if (@it) { $s->{news} = \@it; $news_ok++ } sleep 0.3;
}
note("news: $news_ok of ".scalar(@focus)." focus names have broker headlines");

# Substack: every publication in substacks.json has a free RSS feed (latest ~20 posts; paywalled posts give title + preview only).
my @subs_meta; my $sub_hits = 0; my %feed_codes;
{
  my $cfg = js(slurp('substacks.json')) // [];
  my %stop = map { $_ => 1 } qw(ALL IT ON NOW ARE SO KEY WELL DAY HAS LOW PEG CAT FAST COST TECH PAYC POOL ICE BALL GEN A T C D F K L O V);
  my @pat;
  for my $s (grep { !$_->{stale} } @S) {
    my $c = quotemeta $s->{code}; my @alt;
    if ($s->{m} eq 'ASX') { push @alt, "ASX:\\s?$c\\b", "\\b$c\\.AX\\b" }
    else { push @alt, "\\\$$c\\b", "(?:NYSE|NASDAQ|Nasdaq):\\s?$c\\b"; push @alt, "\\($c\\)" if length($s->{code}) >= 3 && !$stop{$s->{code}}; }
    (my $nm = $s->{name}) =~ s/\s*\(.*?\)//g; 1 while $nm =~ s/[,\s]+(Inc\.?|Corp\.?|Corporation|Company|Co\.?|Limited|Ltd\.?|Group|Holdings?|plc|N\.V\.|& Co\.?|Incorporated|Trust)$//i;
    push @alt, '\b'.quotemeta($nm).'\b' if (length($nm) >= 8 || $nm =~ /\s/) && length($nm) >= 6;
    my $re = join '|', @alt; push @pat, [$s, qr/$re/];
  }
  for my $f (@$cfg) {
    my ($x, $code) = ('', '');
    for my $ua ($UA, 'curl/8', 'Feedfetcher (RSS reader; value-research-desk)') { $x = `curl -sS -L --compressed --max-time 30 -A '$ua' -H 'Accept: application/rss+xml, application/xml, text/xml' -w '
HTTPCODE=%{http_code}' '$f->{feed}' 2>/dev/null` // ''; ($code) = $x =~ /HTTPCODE=(\d+)\s*$/; last if $x =~ /<item>/; sleep 1; }
    $feed_codes{$code // 'none'}++ unless $x =~ /<item>/;
    utf8::decode($x); my ($n, $h) = (0, 0);
    while ($x =~ m{<item>(.*?)</item>}gs) { my $i = $1; $n++;
      my %g; for my $tag (qw(title description link pubDate content:encoded)) { my ($v) = $i =~ m{<\Q$tag\E[^>]*>(.*?)</\Q$tag\E>}s; $v //= ''; $v =~ s/^<!\[CDATA\[|\]\]>$//g; $g{$tag} = $v; }
      my $head = "$g{title} . $g{description}"; (my $body = $g{'content:encoded'}) =~ s/<[^>]+>/ /g;
      for ($head, $body) { s/&amp;/&/g; s/&#36;/\$/g; s/&nbsp;/ /g; }
      for my $p (@pat) { my ($s, $re) = @$p; my $where = $head =~ $re ? 'title' : $body =~ $re ? 'body' : next;
        (my $t = $g{title}) =~ s/&amp;/&/g; push @{$s->{subs}}, { t => $t, u => $g{link}, d => $g{pubDate}, s => $f->{name}, w => $where, k => ($f->{tag} // "value") }; $h++; }
    }
    push @subs_meta, { name => $f->{name}, tag => ($f->{tag} // "value"), url => $f->{url}, posts => $n, hits => $h }; $sub_hits += $h; sleep 0.3;
  }
  for my $s (@S) { next unless $s->{subs}; my @x = sort { ($a->{w} eq 'title' ? 0 : 1) <=> ($b->{w} eq 'title' ? 0 : 1) } @{$s->{subs}}; $s->{subs} = [@x[0 .. ($#x < 5 ? $#x : 5)]]; }
  note("substack: ".scalar(@$cfg)." feeds, ".scalar(grep { $_->{posts} } @subs_meta)." readable, $sub_hits stock mentions".(%feed_codes ? "; unreadable feeds by HTTP status: ".join(', ', map { "$_ x$feed_codes{$_}" } sort keys %feed_codes) : ""));
}

my $xtok = $ENV{X_BEARER_TOKEN} // '';
if ($xtok) {
  my $n = 0;
  for my $s (grep { $_->{verdict} =~ /agree|disagree|quiet/ } @focus) {
    last if ++$n > 30;
    my $tag = $s->{m} eq 'ASX' ? "(\"ASX:$s->{code}\" OR \"$s->{code}.AX\")" : "\"\$$s->{code}\"";
    my $qy = "$tag (research OR \"price target\" OR upgrade OR downgrade OR initiates OR valuation) -is:retweet lang:en";
    my $r = js(curl('https://api.x.com/2/tweets/search/recent?query='.esc($qy).'&max_results=10&tweet.fields=created_at,public_metrics&expansions=author_id&user.fields=username,name', '-H', "Authorization: Bearer $xtok"));
    if ($r && $r->{data}) { my %usr = map { $_->{id} => $_ } @{$r->{includes}{users} // []};
      my @p = sort { ($b->{public_metrics}{like_count} // 0) <=> ($a->{public_metrics}{like_count} // 0) } @{$r->{data}};
      $s->{xposts} = [map { { t => $_->{text}, d => $_->{created_at}, u => 'https://x.com/'.($usr{$_->{author_id}}{username} // 'i').'/status/'.$_->{id}, by => $usr{$_->{author_id}}{username}, likes => $_->{public_metrics}{like_count} } } @p[0 .. ($#p < 4 ? $#p : 4)]]; $x_ok++; }
    elsif ($r && ($r->{title} || $r->{errors})) { note("X API: ".($r->{title} // $r->{detail} // 'error')." - stopping X lookups"); last }
    sleep 1;
  }
  note("X posts: $x_ok names");
} else { note("X posts: skipped (no X_BEARER_TOKEN secret); page shows X search links instead"); }

# ---------- 5. write ----------
delete @$_{qw(epsf epst hi lo)} for @S;
for my $s (@S) { for (keys %$s) { delete $s->{$_} unless defined $s->{$_} } }
my $out = { generated_at => strftime('%Y-%m-%dT%H:%M:%SZ', gmtime $NOW), refresh_url => ($ENV{REFRESH_URL} // ''), x_api => ($xtok && $x_ok ? JSON::PP::true : JSON::PP::false),
  counts => { universe => scalar(@uni), stocks => scalar(@S), stale => $stale, qs_ok => $qs_ok, qs_fail => $qs_fail }, substacks => \@subs_meta, short_date => $SHORT_DATE, log => \@log, stocks => \@S };
make_path($o{out});
my $json = JSON::PP->new->utf8(1)->canonical(1)->encode($out);
open my $h, '>:raw', "$o{out}/data.json" or die $!; print $h $json; close $h;
my $tpl = slurp('template.html'); (my $inl = $json) =~ s{</}{<\\/}g;
$tpl =~ s{(<script type="application/json" id="d-data">)(.*?)(</script>)}{$1$inl$3}s or die "template has no d-data block\n";
open $h, '>:raw', "$o{out}/index.html" or die $!; print $h $tpl; close $h;
note(sprintf "wrote %s/index.html (%.0f KB)", $o{out}, length($tpl) / 1024);
if (my $sum = $ENV{GITHUB_STEP_SUMMARY}) { open my $g, '>>', $sum; print $g "### Value vs Research Desk\n\n", map { "- $_\n" } @log; close $g; }
